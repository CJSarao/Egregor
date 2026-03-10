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
        Task { await runPartialLoop() }
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
            log.log("mode toggled: PTT → OPEN", category: .session)
            hudContinuation.yield(.recording(mode: .open))
            await pipeline.start()
        case .open:
            operatingMode = .ptt
            isRecording = false
            log.log("mode toggled: OPEN → PTT", category: .session)
            hudContinuation.yield(.idle)
            await pipeline.stop()
        }
    }

    private func runPartialLoop() async {
        for await partial in transcriber.partialResults {
            guard isRecording else { continue }
            hudContinuation.yield(.recording(mode: operatingMode, partialText: partial.text))
        }
    }

    private func runSegmentLoop() async {
        for await segment in pipeline.segments {
            let mode = pendingInputMode ?? .dictation
            pendingInputMode = nil
            isRecording = false
            log.log("segment received: duration=\(segment.duration), silenceBefore=\(segment.silenceBefore), mode=\(mode)", category: .session)
            hudContinuation.yield(.transcribing)
            let result = await transcriber.transcribe(segment)
            log.log("transcription: \"\(result.text)\" confidence=\(result.confidence)", category: .session)
            let intent = resolver.resolve(result, mode: mode)
            log.log("resolved intent: \(intent)", category: .session)
            dispatch(intent, result: result)
            if operatingMode == .open {
                isRecording = true
                hudContinuation.yield(.recording(mode: .open))
            }
        }
    }

    private func dispatch(_ intent: Intent, result: TranscriptionResult) {
        switch intent {
        case .inject(let text):
            log.log("dispatch: inject \"\(text)\"", category: .session)
            output.append(text)
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
            log.log("dispatch: discard — text=\"\(result.text)\" confidence=\(result.confidence)", category: .session)
            hudContinuation.yield(.idle)
        }
    }
}
