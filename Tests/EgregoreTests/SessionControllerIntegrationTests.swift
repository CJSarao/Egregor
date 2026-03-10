import XCTest
@testable import Egregore

// MARK: - Test doubles

final class MockHotkeyManager: HotkeyManager, @unchecked Sendable {
    nonisolated let events: AsyncStream<HotkeyEvent>
    private let cont: AsyncStream<HotkeyEvent>.Continuation

    init() {
        var cont: AsyncStream<HotkeyEvent>.Continuation!
        events = AsyncStream { cont = $0 }
        self.cont = cont!
    }

    func emit(_ event: HotkeyEvent) { cont.yield(event) }
}

actor MockAudioPipeline: AudioPipeline {
    nonisolated let segments: AsyncStream<SpeechSegment>
    private let segCont: AsyncStream<SpeechSegment>.Continuation

    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var forceEndCount = 0
    private var nextSegment: SpeechSegment?

    init(nextSegment: SpeechSegment? = nil) {
        var cont: AsyncStream<SpeechSegment>.Continuation!
        segments = AsyncStream { cont = $0 }
        segCont = cont!
        self.nextSegment = nextSegment
    }

    func start() { startCount += 1 }
    func stop()  { stopCount  += 1 }

    func forceEnd() {
        forceEndCount += 1
        if let seg = nextSegment {
            segCont.yield(seg)
            nextSegment = nil
        }
    }

    func setNextSegment(_ seg: SpeechSegment) { nextSegment = seg }
    func emitSegment(_ seg: SpeechSegment)    { segCont.yield(seg) }
}

final class MockTranscriber: Transcriber, @unchecked Sendable {
    nonisolated let partialResults: AsyncStream<PartialTranscription>
    private let partialContinuation: AsyncStream<PartialTranscription>.Continuation
    var result: TranscriptionResult

    init(_ result: TranscriptionResult) {
        self.result = result
        var cont: AsyncStream<PartialTranscription>.Continuation!
        partialResults = AsyncStream { cont = $0 }
        partialContinuation = cont!
    }

    func transcribe(_ segment: SpeechSegment) async -> TranscriptionResult { result }
    func emitPartial(_ text: String) { partialContinuation.yield(PartialTranscription(text: text)) }
}

final class MockOutputManager: OutputManager, @unchecked Sendable {
    private(set) var appended: [String] = []
    private(set) var sendCount  = 0
    private(set) var clearCount = 0

    var onAppend: ((String) -> Void)?
    var onSend:   (() -> Void)?
    var onClear:  (() -> Void)?

    func append(_ text: String) { appended.append(text); onAppend?(text) }
    func send()                 { sendCount  += 1;       onSend?()       }
    func clear()                { clearCount += 1;       onClear?()      }
}

// MARK: - Helpers

private func makeSpeechSegment(
    silenceBefore: Duration = .milliseconds(2000),
    duration: Duration = .milliseconds(800)
) -> SpeechSegment {
    SpeechSegment(audio: [Float](repeating: 0.1, count: 1600), silenceBefore: silenceBefore, duration: duration)
}

private func makeTranscriptionResult(
    text: String,
    confidence: Float = 0.9,
    silenceBefore: Duration = .milliseconds(2000),
    duration: Duration = .milliseconds(800)
) -> TranscriptionResult {
    TranscriptionResult(text: text, confidence: confidence, segment: makeSpeechSegment(silenceBefore: silenceBefore, duration: duration))
}

// MARK: - Tests

final class SessionControllerIntegrationTests: XCTestCase {

    // MARK: PTT dictation: inject path

    func testPTTDictationAppendsTranscribedText() async throws {
        let output = MockOutputManager()
        let exp = expectation(description: "append called")
        output.onAppend = { _ in exp.fulfill() }

        let hotkeys  = MockHotkeyManager()
        let pipeline = MockAudioPipeline(nextSegment: makeSpeechSegment())
        let txr      = MockTranscriber(makeTranscriptionResult(text: "git status"))
        let ctrl     = SessionController(hotkeys: hotkeys, pipeline: pipeline,
                                         transcriber: txr, resolver: EgregoreIntentResolver(), output: output)
        await ctrl.start()

        hotkeys.emit(.pttBegan)
        hotkeys.emit(.pttEnded(mode: .dictation))

        await fulfillment(of: [exp], timeout: 2)
        XCTAssertEqual(output.appended, ["git status"])
        XCTAssertEqual(output.sendCount, 0)
        XCTAssertEqual(output.clearCount, 0)
    }

    // MARK: PTT dictation: discard is no-op

    func testPTTDictationDiscardIsNoOp() async throws {
        let output = MockOutputManager()
        let exp    = expectation(description: "no append")
        exp.isInverted = true
        output.onAppend = { _ in exp.fulfill() }
        output.onSend   = { exp.fulfill() }
        output.onClear  = { exp.fulfill() }

        let segment = makeSpeechSegment()
        // confidence 0.05 → below confidence floor → .discard
        let hotkeys  = MockHotkeyManager()
        let pipeline = MockAudioPipeline(nextSegment: segment)
        let txr      = MockTranscriber(makeTranscriptionResult(text: "noise", confidence: 0.05))
        let ctrl     = SessionController(hotkeys: hotkeys, pipeline: pipeline,
                                         transcriber: txr, resolver: EgregoreIntentResolver(), output: output)
        await ctrl.start()

        hotkeys.emit(.pttBegan)
        hotkeys.emit(.pttEnded(mode: .dictation))

        await fulfillment(of: [exp], timeout: 0.5)
        XCTAssertEqual(output.appended, [])
        XCTAssertEqual(output.sendCount, 0)
        XCTAssertEqual(output.clearCount, 0)
    }

    // MARK: PTT command mode: ROGER → send

    func testPTTCommandModeRogerCallsSend() async throws {
        let output = MockOutputManager()
        let exp    = expectation(description: "send called")
        output.onSend = { exp.fulfill() }

        let hotkeys  = MockHotkeyManager()
        let pipeline = MockAudioPipeline(nextSegment: makeSpeechSegment())
        let txr      = MockTranscriber(makeTranscriptionResult(text: "ROGER"))
        let ctrl     = SessionController(hotkeys: hotkeys, pipeline: pipeline,
                                         transcriber: txr, resolver: EgregoreIntentResolver(), output: output)
        await ctrl.start()

        hotkeys.emit(.pttBegan)
        hotkeys.emit(.pttEnded(mode: .command))

        await fulfillment(of: [exp], timeout: 2)
        XCTAssertEqual(output.sendCount, 1)
        XCTAssertEqual(output.appended, [])
        XCTAssertEqual(output.clearCount, 0)
    }

    // MARK: PTT command mode: ABORT → clear

    func testPTTCommandModeAbortCallsClear() async throws {
        let output = MockOutputManager()
        let exp    = expectation(description: "clear called")
        output.onClear = { exp.fulfill() }

        let hotkeys  = MockHotkeyManager()
        let pipeline = MockAudioPipeline(nextSegment: makeSpeechSegment())
        let txr      = MockTranscriber(makeTranscriptionResult(text: "ABORT"))
        let ctrl     = SessionController(hotkeys: hotkeys, pipeline: pipeline,
                                         transcriber: txr, resolver: EgregoreIntentResolver(), output: output)
        await ctrl.start()

        hotkeys.emit(.pttBegan)
        hotkeys.emit(.pttEnded(mode: .command))

        await fulfillment(of: [exp], timeout: 2)
        XCTAssertEqual(output.clearCount, 1)
        XCTAssertEqual(output.appended, [])
        XCTAssertEqual(output.sendCount, 0)
    }

    // MARK: PTT command mode: non-vocabulary → discard, never inject

    func testPTTCommandModeNonVocabularyNeverInjects() async throws {
        let output = MockOutputManager()
        let exp    = expectation(description: "no inject or send")
        exp.isInverted = true
        output.onAppend = { _ in exp.fulfill() }
        output.onSend   = { exp.fulfill() }
        output.onClear  = { exp.fulfill() }

        let hotkeys  = MockHotkeyManager()
        let pipeline = MockAudioPipeline(nextSegment: makeSpeechSegment())
        let txr      = MockTranscriber(makeTranscriptionResult(text: "git status"))
        let ctrl     = SessionController(hotkeys: hotkeys, pipeline: pipeline,
                                         transcriber: txr, resolver: EgregoreIntentResolver(), output: output)
        await ctrl.start()

        hotkeys.emit(.pttBegan)
        hotkeys.emit(.pttEnded(mode: .command))

        await fulfillment(of: [exp], timeout: 0.5)
        XCTAssertEqual(output.appended, [])
        XCTAssertEqual(output.sendCount, 0)
        XCTAssertEqual(output.clearCount, 0)
    }

    // MARK: Mode toggle switches to OPEN and back to PTT

    func testModeToggleSwitchesToOpenAndStartsPipeline() async throws {
        let hotkeys  = MockHotkeyManager()
        let pipeline = MockAudioPipeline()
        let txr      = MockTranscriber(makeTranscriptionResult(text: ""))
        let output   = MockOutputManager()
        let ctrl     = SessionController(hotkeys: hotkeys, pipeline: pipeline,
                                         transcriber: txr, resolver: EgregoreIntentResolver(), output: output)
        await ctrl.start()

        hotkeys.emit(.modeToggled)
        // Yield control to let the hotkey loop process the event
        try await Task.sleep(nanoseconds: 50_000_000)

        let mode       = await ctrl.operatingMode
        let startCount = await pipeline.startCount
        XCTAssertEqual(mode, .open)
        XCTAssertEqual(startCount, 1)
    }

    func testModeToggledTwiceReturnsToPTT() async throws {
        let hotkeys  = MockHotkeyManager()
        let pipeline = MockAudioPipeline()
        let txr      = MockTranscriber(makeTranscriptionResult(text: ""))
        let output   = MockOutputManager()
        let ctrl     = SessionController(hotkeys: hotkeys, pipeline: pipeline,
                                         transcriber: txr, resolver: EgregoreIntentResolver(), output: output)
        await ctrl.start()

        hotkeys.emit(.modeToggled)
        hotkeys.emit(.modeToggled)
        try await Task.sleep(nanoseconds: 100_000_000)

        let mode      = await ctrl.operatingMode
        let stopCount = await pipeline.stopCount
        XCTAssertEqual(mode, .ptt)
        XCTAssertGreaterThanOrEqual(stopCount, 1)
    }

    // MARK: OPEN mode: normal utterance appends text

    func testOpenModeNormalUtteranceAppends() async throws {
        let output = MockOutputManager()
        let exp    = expectation(description: "append called in OPEN mode")
        output.onAppend = { _ in exp.fulfill() }

        let hotkeys  = MockHotkeyManager()
        let pipeline = MockAudioPipeline()
        // Non-isolated (short silenceBefore) → inject
        let txr = MockTranscriber(makeTranscriptionResult(text: "ls -la", silenceBefore: .milliseconds(200)))
        let ctrl = SessionController(hotkeys: hotkeys, pipeline: pipeline,
                                     transcriber: txr, resolver: EgregoreIntentResolver(), output: output)
        await ctrl.start()

        hotkeys.emit(.modeToggled)               // enter OPEN mode
        try await Task.sleep(nanoseconds: 30_000_000)
        await pipeline.emitSegment(makeSpeechSegment(silenceBefore: .milliseconds(200)))

        await fulfillment(of: [exp], timeout: 2)
        XCTAssertEqual(output.appended, ["ls -la"])
    }

    // MARK: OPEN mode: isolated ROGER → send

    func testOpenModeIsolatedRogerCallsSend() async throws {
        let output = MockOutputManager()
        let exp    = expectation(description: "send called in OPEN mode")
        output.onSend = { exp.fulfill() }

        let hotkeys  = MockHotkeyManager()
        let pipeline = MockAudioPipeline()
        // Isolated utterance: silenceBefore > 1500ms, duration < 2000ms → command
        let txr = MockTranscriber(makeTranscriptionResult(text: "ROGER",
                                                          silenceBefore: .milliseconds(2000),
                                                          duration: .milliseconds(800)))
        let ctrl = SessionController(hotkeys: hotkeys, pipeline: pipeline,
                                     transcriber: txr, resolver: EgregoreIntentResolver(), output: output)
        await ctrl.start()

        hotkeys.emit(.modeToggled)
        try await Task.sleep(nanoseconds: 30_000_000)
        await pipeline.emitSegment(makeSpeechSegment(silenceBefore: .milliseconds(2000), duration: .milliseconds(800)))

        await fulfillment(of: [exp], timeout: 2)
        XCTAssertEqual(output.sendCount, 1)
        XCTAssertEqual(output.appended, [])
    }

    // MARK: OPEN mode: isolated ABORT → clear

    func testOpenModeIsolatedAbortCallsClear() async throws {
        let output = MockOutputManager()
        let exp    = expectation(description: "clear called in OPEN mode")
        output.onClear = { exp.fulfill() }

        let hotkeys  = MockHotkeyManager()
        let pipeline = MockAudioPipeline()
        let txr = MockTranscriber(makeTranscriptionResult(text: "ABORT",
                                                          silenceBefore: .milliseconds(2000),
                                                          duration: .milliseconds(800)))
        let ctrl = SessionController(hotkeys: hotkeys, pipeline: pipeline,
                                     transcriber: txr, resolver: EgregoreIntentResolver(), output: output)
        await ctrl.start()

        hotkeys.emit(.modeToggled)
        try await Task.sleep(nanoseconds: 30_000_000)
        await pipeline.emitSegment(makeSpeechSegment(silenceBefore: .milliseconds(2000), duration: .milliseconds(800)))

        await fulfillment(of: [exp], timeout: 2)
        XCTAssertEqual(output.clearCount, 1)
        XCTAssertEqual(output.appended, [])
    }

    // MARK: PTT ignores segment events in OPEN mode

    func testPTTEventIgnoredInOpenMode() async throws {
        let output = MockOutputManager()
        let exp    = expectation(description: "no PTT action in OPEN mode")
        exp.isInverted = true
        output.onAppend = { _ in exp.fulfill() }
        output.onSend   = { exp.fulfill() }
        output.onClear  = { exp.fulfill() }

        let hotkeys  = MockHotkeyManager()
        let pipeline = MockAudioPipeline(nextSegment: makeSpeechSegment())
        let txr      = MockTranscriber(makeTranscriptionResult(text: "ROGER"))
        let ctrl     = SessionController(hotkeys: hotkeys, pipeline: pipeline,
                                         transcriber: txr, resolver: EgregoreIntentResolver(), output: output)
        await ctrl.start()

        hotkeys.emit(.modeToggled)           // switch to OPEN
        try await Task.sleep(nanoseconds: 30_000_000)
        hotkeys.emit(.pttBegan)              // PTT ignored in OPEN mode
        hotkeys.emit(.pttEnded(mode: .command))

        await fulfillment(of: [exp], timeout: 0.5)
        // No segment emitted for PTT in OPEN mode — pipeline.forceEnd never called
        let feCount = await pipeline.forceEndCount
        XCTAssertEqual(feCount, 0)
    }
}
