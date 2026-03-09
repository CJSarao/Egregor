import Foundation

actor SessionController {
    enum OperatingMode { case ptt, open }

    private let hotkeys: any HotkeyManager
    private let pipeline: any AudioPipeline
    private let transcriber: any Transcriber
    private let resolver: any IntentResolver
    private let output: any OutputManager

    private(set) var operatingMode: OperatingMode = .ptt
    private var pendingInputMode: InputMode?

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
            await pipeline.start()
        case .open:
            operatingMode = .ptt
            await pipeline.stop()
        }
    }

    private func runSegmentLoop() async {
        for await segment in pipeline.segments {
            let mode = pendingInputMode ?? .dictation
            pendingInputMode = nil
            let result = await transcriber.transcribe(segment)
            let intent = resolver.resolve(result, mode: mode)
            dispatch(intent)
        }
    }

    private func dispatch(_ intent: Intent) {
        switch intent {
        case .inject(let text): output.append(text)
        case .command(.roger):  output.send()
        case .command(.abort):  output.clear()
        case .discard:          break
        }
    }
}
