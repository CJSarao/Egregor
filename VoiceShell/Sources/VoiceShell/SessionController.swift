import Foundation

actor SessionController {
    enum OperatingMode: Equatable { case ptt, open }

    private let hotkeys: any HotkeyManager
    private let pipeline: any AudioPipeline
    private let transcriber: any Transcriber
    private let resolver: any IntentResolver
    private let output: any OutputManager

    private(set) var operatingMode: OperatingMode = .ptt
    private var pendingInputMode: InputMode?

    nonisolated let hudStates: AsyncStream<HUDState>
    private let hudContinuation: AsyncStream<HUDState>.Continuation

    init(
        hotkeys: any HotkeyManager,
        pipeline: any AudioPipeline,
        transcriber: any Transcriber,
        resolver: any IntentResolver,
        output: any OutputManager
    ) {
        self.hotkeys = hotkeys
        self.pipeline = pipeline
        self.transcriber = transcriber
        self.resolver = resolver
        self.output = output

        var cont: AsyncStream<HUDState>.Continuation!
        hudStates = AsyncStream { cont = $0 }
        hudContinuation = cont!
    }

    func start() {
        Task { await runHotkeyLoop() }
        Task { await runSegmentLoop() }
    }

    private func runHotkeyLoop() async {
        for await event in hotkeys.events {
            await handle(event)
        }
    }

    private func handle(_ event: HotkeyEvent) async {
        switch event {
        case .pttBegan:
            guard operatingMode == .ptt else { return }
            hudContinuation.yield(.recording(mode: .ptt))
            await pipeline.start()
        case .pttEnded(let mode):
            guard operatingMode == .ptt else { return }
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
            hudContinuation.yield(.recording(mode: .open))
            await pipeline.start()
        case .open:
            operatingMode = .ptt
            hudContinuation.yield(.idle)
            await pipeline.stop()
        }
    }

    private func runSegmentLoop() async {
        for await segment in pipeline.segments {
            let mode = pendingInputMode ?? .dictation
            pendingInputMode = nil
            hudContinuation.yield(.transcribing)
            let result = await transcriber.transcribe(segment)
            let intent = resolver.resolve(result, mode: mode)
            dispatch(intent)
        }
    }

    private func dispatch(_ intent: Intent) {
        switch intent {
        case .inject(let text):
            output.append(text)
            hudContinuation.yield(.injected(text))
        case .command(.roger):
            output.send()
            hudContinuation.yield(.injected("⏎"))
        case .command(.abort):
            output.clear()
            hudContinuation.yield(.cleared)
        case .discard:
            hudContinuation.yield(.idle)
        }
    }
}
