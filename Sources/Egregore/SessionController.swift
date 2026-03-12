import Foundation

actor SessionController {

    private let hotkeys: any HotkeyManager
    private let pipeline: any AudioPipeline
    private let transcriber: any Transcriber
    private let resolver: any IntentResolver
    private let output: any OutputManager
    private let log: RuntimeLogger

    private var isRecording = false
    private var partialTask: Task<Void, Never>?

    nonisolated let hudStates: AsyncStream<HUDState>
    private let hudContinuation: AsyncStream<HUDState>.Continuation

    init(
        hotkeys: any HotkeyManager,
        pipeline: any AudioPipeline,
        transcriber: any Transcriber,
        resolver: any IntentResolver,
        output: any OutputManager,
        logger: RuntimeLogger = .shared
    ) {
        self.hotkeys = hotkeys
        self.pipeline = pipeline
        self.transcriber = transcriber
        self.resolver = resolver
        self.output = output
        self.log = logger

        var cont: AsyncStream<HUDState>.Continuation!
        hudStates = AsyncStream { cont = $0 }
        hudContinuation = cont!
    }

    func start() {
        Task { await runHotkeyLoop() }
        Task { await runSegmentLoop() }
        Task { await runCaptureSnapshotLoop() }
        Task { await runPartialStreamLoop() }
    }

    private func runHotkeyLoop() async {
        for await event in hotkeys.events {
            await handle(event)
        }
    }

    private func handle(_ event: HotkeyEvent) async {
        log.log("hotkey event: \(event)", category: .session)
        switch event {
        case .toggle:
            if isRecording {
                isRecording = false
                cancelPartialTask()
                log.log("toggle → stop recording", category: .session)
                hudContinuation.yield(.idle)
                await pipeline.stop()
            } else {
                isRecording = true
                resetPartialTracking()
                log.log("toggle → start recording", category: .session)
                hudContinuation.yield(.recording())
                await pipeline.start()
            }
        }
    }

    private func runCaptureSnapshotLoop() async {
        for await snapshot in pipeline.captureSnapshots {
            guard isRecording else { continue }
            cancelPartialTask()
            partialTask = Task {
                _ = await self.transcriber.transcribePartial(snapshot)
            }
        }
    }

    private func runPartialStreamLoop() async {
        for await text in transcriber.partialTextStream {
            guard isRecording, !text.isEmpty else { continue }
            hudContinuation.yield(.recording(partialText: text))
        }
    }

    private func runSegmentLoop() async {
        for await segment in pipeline.segments {
            isRecording = false
            cancelPartialTask()
            log.log("segment received: duration=\(segment.duration), silenceBefore=\(segment.silenceBefore), trailingSilenceAfter=\(segment.trailingSilenceAfter), endedBySilence=\(segment.endedBySilence)", category: .session)
            hudContinuation.yield(.transcribing)
            let result = await transcriber.transcribe(segment)
            log.log("transcription: chars=\(result.text.count) confidence=\(result.confidence)", category: .session)
            let intent = resolver.resolve(result)
            log.log("resolved intent: \(intent)", category: .session)
            dispatch(intent, result: result)
            if isRecording == false {
                isRecording = true
                resetPartialTracking()
                hudContinuation.yield(.recording())
            }
        }
    }

    private func dispatch(_ intent: Intent, result: TranscriptionResult) {
        switch intent {
        case .inject(let text):
            log.log("dispatch: inject chars=\(text.count)", category: .session)
            switch output.append(text) {
            case .success:
                log.log("dispatch: append handed to output manager", category: .session)
                hudContinuation.yield(.injected(text))
            case .failure(let message):
                log.error("dispatch: append failed: \(message)", category: .session)
                hudContinuation.yield(.error(message))
            }
        case .command(.roger):
            log.log("dispatch: ROGER → send (confidence=\(result.confidence))", category: .session)
            switch output.send() {
            case .success:
                hudContinuation.yield(.injected("⏎"))
            case .failure(let message):
                log.error("dispatch: send failed: \(message)", category: .session)
                hudContinuation.yield(.error(message))
            }
        case .command(.abort):
            log.log("dispatch: ABORT → clear (confidence=\(result.confidence))", category: .session)
            switch output.clear() {
            case .success:
                hudContinuation.yield(.cleared)
            case .failure(let message):
                log.error("dispatch: clear failed: \(message)", category: .session)
                hudContinuation.yield(.error(message))
            }
        case .discard:
            log.log("dispatch: discard chars=\(result.text.count) confidence=\(result.confidence)", category: .session)
            hudContinuation.yield(.idle)
        }
    }

    private func resetPartialTracking() {
        cancelPartialTask()
    }

    private func cancelPartialTask() {
        partialTask?.cancel()
        partialTask = nil
    }
}
