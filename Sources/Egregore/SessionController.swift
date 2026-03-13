import Foundation

actor SessionController {

    private let hotkeys: any HotkeyManager
    private let pipeline: any AudioPipeline
    private let transcriber: any Transcriber
    private let resolver: any IntentResolver
    private let output: any OutputManager
    private let textNormalizer: TerminalTextNormalizer
    private let log: RuntimeLogger

    private var isMicOpen = false
    private var acceptsPartialUpdates = false
    private var pendingSnapshot: SpeechCaptureSnapshot?
    private var lastLiveTranscript: String?
    private var partialTask: Task<Void, Never>?

    nonisolated let hudStates: AsyncStream<HUDState>
    private let hudContinuation: AsyncStream<HUDState>.Continuation

    init(
        hotkeys: any HotkeyManager,
        pipeline: any AudioPipeline,
        transcriber: any Transcriber,
        resolver: any IntentResolver,
        output: any OutputManager,
        textNormalizer: TerminalTextNormalizer = TerminalTextNormalizer(),
        logger: RuntimeLogger = .shared
    ) {
        self.hotkeys = hotkeys
        self.pipeline = pipeline
        self.transcriber = transcriber
        self.resolver = resolver
        self.output = output
        self.textNormalizer = textNormalizer
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
            if isMicOpen {
                isMicOpen = false
                stopCurrentUtterance()
                log.log("toggle → stop recording", category: .session)
                hudContinuation.yield(.idle)
                await pipeline.stop()
            } else {
                isMicOpen = true
                beginListeningCycle()
                log.log("toggle → start recording", category: .session)
                hudContinuation.yield(.listening)
                await pipeline.start()
            }
        }
    }

    private func runCaptureSnapshotLoop() async {
        for await snapshot in pipeline.captureSnapshots {
            guard isMicOpen, acceptsPartialUpdates else { continue }
            pendingSnapshot = snapshot
            ensurePartialWorker()
        }
    }

    private func runPartialStreamLoop() async {
        for await text in transcriber.partialTextStream {
            guard isMicOpen, acceptsPartialUpdates else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != lastLiveTranscript else { continue }
            lastLiveTranscript = trimmed
            hudContinuation.yield(.recording(partialText: trimmed))
        }
    }

    private func runSegmentLoop() async {
        for await segment in pipeline.segments {
            guard isMicOpen else { continue }
            stopCurrentUtterance()
            log.log("segment received: duration=\(segment.duration), silenceBefore=\(segment.silenceBefore), trailingSilenceAfter=\(segment.trailingSilenceAfter), endedBySilence=\(segment.endedBySilence)", category: .session)
            hudContinuation.yield(.transcribing(lastText: lastLiveTranscript))
            let result = await transcriber.transcribe(segment)
            log.log("transcription: chars=\(result.text.count) confidence=\(result.confidence)", category: .session)
            let intent = resolver.resolve(result)
            log.log("resolved intent: \(intent)", category: .session)
            dispatch(intent, result: result)
            if isMicOpen { beginListeningCycle() }
        }
    }

    private func dispatch(_ intent: Intent, result: TranscriptionResult) {
        let continueListening = isMicOpen
        switch intent {
        case .inject(let text):
            let normalized = textNormalizer.normalizeForInjection(text)
            guard !normalized.isEmpty else {
                log.log("dispatch: inject normalized to empty text, dropping utterance", category: .session)
                hudContinuation.yield(continueListening ? .listening : .idle)
                return
            }
            log.log("dispatch: inject chars=\(normalized.count)", category: .session)
            switch output.append(normalized) {
            case .success:
                log.log("dispatch: append handed to output manager", category: .session)
                hudContinuation.yield(.injected(normalized, continueListening: continueListening))
            case .failure(let message):
                log.error("dispatch: append failed: \(message)", category: .session)
                hudContinuation.yield(.error(message, continueListening: continueListening))
            }
        case .command(.roger):
            log.log("dispatch: ROGER → send (confidence=\(result.confidence))", category: .session)
            switch output.send() {
            case .success:
                hudContinuation.yield(.injected("⏎", continueListening: continueListening))
            case .failure(let message):
                log.error("dispatch: send failed: \(message)", category: .session)
                hudContinuation.yield(.error(message, continueListening: continueListening))
            }
        case .command(.abort):
            log.log("dispatch: ABORT → clear (confidence=\(result.confidence))", category: .session)
            switch output.clear() {
            case .success:
                hudContinuation.yield(.cleared(continueListening: continueListening))
            case .failure(let message):
                log.error("dispatch: clear failed: \(message)", category: .session)
                hudContinuation.yield(.error(message, continueListening: continueListening))
            }
        case .discard:
            log.log("dispatch: discard chars=\(result.text.count) confidence=\(result.confidence)", category: .session)
            hudContinuation.yield(continueListening ? .listening : .idle)
        }
    }

    private func beginListeningCycle() {
        acceptsPartialUpdates = true
        lastLiveTranscript = nil
        pendingSnapshot = nil
    }

    private func stopCurrentUtterance() {
        acceptsPartialUpdates = false
        pendingSnapshot = nil
        partialTask?.cancel()
        partialTask = nil
    }

    private func ensurePartialWorker() {
        guard partialTask == nil else { return }
        partialTask = Task {
            await self.runPartialWorkerLoop()
        }
    }

    private func runPartialWorkerLoop() async {
        while !Task.isCancelled {
            guard let snapshot = pendingSnapshot else {
                partialTask = nil
                return
            }
            pendingSnapshot = nil
            _ = await transcriber.transcribePartial(snapshot)
        }
        partialTask = nil
    }
}
