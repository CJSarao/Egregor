import Foundation

actor SessionController {
    enum OperatingMode: Equatable { case ptt, open }

    private let hotkeys: any HotkeyManager
    private let pipeline: any AudioPipeline
    private let transcriber: any Transcriber
    private let resolver: any IntentResolver
    private let output: any OutputManager
    private let log: RuntimeLogger

    private(set) var operatingMode: OperatingMode = .ptt
    private var pendingInputMode: InputMode?
    private var isRecording = false
    private var partialSequence = 0
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
    }

    private func runHotkeyLoop() async {
        for await event in hotkeys.events {
            await handle(event)
        }
    }

    private func handle(_ event: HotkeyEvent) async {
        log.log("hotkey event: \(event)", category: .session)
        switch event {
        case .pttBegan:
            guard operatingMode == .ptt else {
                log.log("pttBegan ignored (OPEN mode active)", category: .session)
                return
            }
            isRecording = true
            resetPartialTracking()
            hudContinuation.yield(.recording(mode: .ptt))
            await pipeline.start()
        case .pttEnded(let mode):
            guard operatingMode == .ptt else {
                log.log("pttEnded ignored (OPEN mode active)", category: .session)
                return
            }
            pendingInputMode = mode
            await pipeline.forceEnd()
            await pipeline.stop()
        case .modeToggled:
            await toggleMode()
        }
    }

    private func toggleMode() async {
        switch operatingMode {
        case .ptt:
            operatingMode = .open
            isRecording = true
            resetPartialTracking()
            log.log("mode toggled: PTT → OPEN", category: .session)
            hudContinuation.yield(.recording(mode: .open))
            await pipeline.start()
        case .open:
            operatingMode = .ptt
            isRecording = false
            cancelPartialTask()
            log.log("mode toggled: OPEN → PTT", category: .session)
            hudContinuation.yield(.idle)
            await pipeline.stop()
        }
    }

    private func runCaptureSnapshotLoop() async {
        for await snapshot in pipeline.captureSnapshots {
            guard isRecording else { continue }
            partialSequence += 1
            let sequence = partialSequence
            let mode = operatingMode
            cancelPartialTask()
            partialTask = Task {
                let text = await self.transcriber.transcribePartial(snapshot)
                await self.applyPartialTranscript(text, sequence: sequence, mode: mode)
            }
        }
    }

    private func runSegmentLoop() async {
        for await segment in pipeline.segments {
            let mode = pendingInputMode ?? .dictation
            pendingInputMode = nil
            isRecording = false
            cancelPartialTask()
            log.log("segment received: duration=\(segment.duration), silenceBefore=\(segment.silenceBefore), mode=\(mode)", category: .session)
            hudContinuation.yield(.transcribing)
            let result = await transcriber.transcribe(segment)
            log.log("transcription: chars=\(result.text.count) confidence=\(result.confidence)", category: .session)
            let intent = resolver.resolve(result, mode: mode)
            log.log("resolved intent: \(intent)", category: .session)
            dispatch(intent, result: result)
            if operatingMode == .open {
                isRecording = true
                resetPartialTracking()
                hudContinuation.yield(.recording(mode: .open))
            }
        }
    }

    private func applyPartialTranscript(_ text: String, sequence: Int, mode: OperatingMode) async {
        guard isRecording, sequence == partialSequence, !text.isEmpty else { return }
        hudContinuation.yield(.recording(mode: mode, partialText: text))
    }

    private func dispatch(_ intent: Intent, result: TranscriptionResult) {
        switch intent {
        case .inject(let text):
            log.log("dispatch: inject chars=\(text.count)", category: .session)
            output.append(text)
            log.log("dispatch: append handed to output manager", category: .session)
            hudContinuation.yield(.injected(text))
        case .command(.roger):
            log.log("dispatch: ROGER → send (confidence=\(result.confidence))", category: .session)
            output.send()
            hudContinuation.yield(.injected("⏎"))
        case .command(.abort):
            log.log("dispatch: ABORT → clear (confidence=\(result.confidence))", category: .session)
            output.clear()
            hudContinuation.yield(.cleared)
        case .discard:
            log.log("dispatch: discard chars=\(result.text.count) confidence=\(result.confidence)", category: .session)
            hudContinuation.yield(.idle)
        }
    }

    private func resetPartialTracking() {
        partialSequence += 1
        cancelPartialTask()
    }

    private func cancelPartialTask() {
        partialTask?.cancel()
        partialTask = nil
    }
}
