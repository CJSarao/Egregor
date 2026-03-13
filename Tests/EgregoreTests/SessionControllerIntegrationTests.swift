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
    nonisolated let captureSnapshots: AsyncStream<SpeechCaptureSnapshot>
    private let snapshotCont: AsyncStream<SpeechCaptureSnapshot>.Continuation

    private(set) var startCount = 0
    private(set) var stopCount = 0

    init() {
        var segmentCont: AsyncStream<SpeechSegment>.Continuation!
        segments = AsyncStream { segmentCont = $0 }
        segCont = segmentCont!
        var partialCont: AsyncStream<SpeechCaptureSnapshot>.Continuation!
        captureSnapshots = AsyncStream { partialCont = $0 }
        snapshotCont = partialCont!
    }

    func start() { startCount += 1 }
    func stop()  { stopCount  += 1 }

    func emitSegment(_ seg: SpeechSegment)    { segCont.yield(seg) }
    func emitSnapshot(_ snapshot: SpeechCaptureSnapshot) { snapshotCont.yield(snapshot) }
}

final class MockTranscriber: Transcriber, @unchecked Sendable {
    var result: TranscriptionResult
    var partialText = ""

    nonisolated let partialTextStream: AsyncStream<String>
    private let partialContinuation: AsyncStream<String>.Continuation

    init(_ result: TranscriptionResult) {
        self.result = result
        var cont: AsyncStream<String>.Continuation!
        partialTextStream = AsyncStream { cont = $0 }
        partialContinuation = cont!
    }

    func emitPartial(_ text: String) { partialContinuation.yield(text) }
    func transcribePartial(_ snapshot: SpeechCaptureSnapshot) async -> String { partialText }
    func transcribe(_ segment: SpeechSegment) async -> TranscriptionResult { result }
}

final class MockOutputManager: OutputManager, @unchecked Sendable {
    private(set) var appended: [String] = []
    private(set) var sendCount  = 0
    private(set) var clearCount = 0
    var appendResult: OutputResult = .success
    var sendResult: OutputResult = .success
    var clearResult: OutputResult = .success

    var onAppend: ((String) -> Void)?
    var onSend:   (() -> Void)?
    var onClear:  (() -> Void)?

    func append(_ text: String) -> OutputResult {
        appended.append(text)
        onAppend?(text)
        return appendResult
    }

    func send() -> OutputResult {
        sendCount += 1
        onSend?()
        return sendResult
    }

    func clear() -> OutputResult {
        clearCount += 1
        onClear?()
        return clearResult
    }
}

// MARK: - Helpers

private func makeSpeechSegment(
    silenceBefore: Duration = .milliseconds(2000),
    duration: Duration = .milliseconds(800),
    trailingSilenceAfter: Duration = .zero,
    endedBySilence: Bool = false
) -> SpeechSegment {
    SpeechSegment(audio: [Float](repeating: 0.1, count: 1600),
                  silenceBefore: silenceBefore,
                  duration: duration,
                  trailingSilenceAfter: trailingSilenceAfter,
                  endedBySilence: endedBySilence)
}

private func makeCaptureSnapshot(
    duration: Duration = .milliseconds(300)
) -> SpeechCaptureSnapshot {
    SpeechCaptureSnapshot(audio: [Float](repeating: 0.1, count: 3200), duration: duration)
}

private func makeTranscriptionResult(
    text: String,
    confidence: Float = 0.9,
    silenceBefore: Duration = .milliseconds(2000),
    duration: Duration = .milliseconds(800),
    trailingSilenceAfter: Duration = .zero,
    endedBySilence: Bool = false
) -> TranscriptionResult {
    TranscriptionResult(text: text,
                        confidence: confidence,
                        segment: makeSpeechSegment(silenceBefore: silenceBefore,
                                                  duration: duration,
                                                  trailingSilenceAfter: trailingSilenceAfter,
                                                  endedBySilence: endedBySilence))
}

// MARK: - Tests

final class SessionControllerIntegrationTests: XCTestCase {

    // MARK: Toggle on → dictation inject

    func testToggleOnDictationAppendsTranscribedText() async throws {
        let output = MockOutputManager()
        let exp = expectation(description: "append called")
        output.onAppend = { _ in exp.fulfill() }

        let hotkeys  = MockHotkeyManager()
        let pipeline = MockAudioPipeline()
        let txr      = MockTranscriber(makeTranscriptionResult(text: "git status"))
        let ctrl     = SessionController(hotkeys: hotkeys, pipeline: pipeline,
                                         transcriber: txr, resolver: EgregoreIntentResolver(), output: output)
        await ctrl.start()

        hotkeys.emit(.toggle)
        try await Task.sleep(nanoseconds: 30_000_000)
        await pipeline.emitSegment(makeSpeechSegment())

        await fulfillment(of: [exp], timeout: 2)
        XCTAssertEqual(output.appended, ["git status"])
        XCTAssertEqual(output.sendCount, 0)
        XCTAssertEqual(output.clearCount, 0)
    }

    // MARK: Discard is no-op

    func testDictationDiscardIsNoOp() async throws {
        let output = MockOutputManager()
        let exp    = expectation(description: "no append")
        exp.isInverted = true
        output.onAppend = { _ in exp.fulfill() }
        output.onSend   = { exp.fulfill() }
        output.onClear  = { exp.fulfill() }

        let hotkeys  = MockHotkeyManager()
        let pipeline = MockAudioPipeline()
        let txr      = MockTranscriber(makeTranscriptionResult(text: "noise", confidence: 0.05))
        let ctrl     = SessionController(hotkeys: hotkeys, pipeline: pipeline,
                                         transcriber: txr, resolver: EgregoreIntentResolver(), output: output)
        await ctrl.start()

        hotkeys.emit(.toggle)
        try await Task.sleep(nanoseconds: 30_000_000)
        await pipeline.emitSegment(makeSpeechSegment())

        await fulfillment(of: [exp], timeout: 0.5)
        XCTAssertEqual(output.appended, [])
        XCTAssertEqual(output.sendCount, 0)
        XCTAssertEqual(output.clearCount, 0)
    }

    // MARK: Toggle starts and stops pipeline

    func testToggleOnStartsPipeline() async throws {
        let hotkeys  = MockHotkeyManager()
        let pipeline = MockAudioPipeline()
        let txr      = MockTranscriber(makeTranscriptionResult(text: ""))
        let output   = MockOutputManager()
        let ctrl     = SessionController(hotkeys: hotkeys, pipeline: pipeline,
                                         transcriber: txr, resolver: EgregoreIntentResolver(), output: output)
        await ctrl.start()

        hotkeys.emit(.toggle)
        try await Task.sleep(nanoseconds: 50_000_000)

        let startCount = await pipeline.startCount
        XCTAssertEqual(startCount, 1)
    }

    func testToggleTwiceStopsPipeline() async throws {
        let hotkeys  = MockHotkeyManager()
        let pipeline = MockAudioPipeline()
        let txr      = MockTranscriber(makeTranscriptionResult(text: ""))
        let output   = MockOutputManager()
        let ctrl     = SessionController(hotkeys: hotkeys, pipeline: pipeline,
                                         transcriber: txr, resolver: EgregoreIntentResolver(), output: output)
        await ctrl.start()

        hotkeys.emit(.toggle)
        hotkeys.emit(.toggle)
        try await Task.sleep(nanoseconds: 100_000_000)

        let stopCount = await pipeline.stopCount
        XCTAssertGreaterThanOrEqual(stopCount, 1)
    }

    // MARK: Normal utterance appends text

    func testNormalUtteranceAppends() async throws {
        let output = MockOutputManager()
        let exp    = expectation(description: "append called")
        output.onAppend = { _ in exp.fulfill() }

        let hotkeys  = MockHotkeyManager()
        let pipeline = MockAudioPipeline()
        let txr = MockTranscriber(makeTranscriptionResult(text: "ls -la",
                                                          silenceBefore: .milliseconds(200),
                                                          duration: .milliseconds(800),
                                                          trailingSilenceAfter: .milliseconds(900),
                                                          endedBySilence: true))
        let ctrl = SessionController(hotkeys: hotkeys, pipeline: pipeline,
                                     transcriber: txr, resolver: EgregoreIntentResolver(), output: output)
        await ctrl.start()

        hotkeys.emit(.toggle)
        try await Task.sleep(nanoseconds: 30_000_000)
        await pipeline.emitSegment(makeSpeechSegment(silenceBefore: .milliseconds(200),
                                                     duration: .milliseconds(800),
                                                     trailingSilenceAfter: .milliseconds(900),
                                                     endedBySilence: true))

        await fulfillment(of: [exp], timeout: 2)
        XCTAssertEqual(output.appended, ["ls -la"])
    }

    func testNormalUtteranceStripsTrailingPunctuationBeforeAppend() async throws {
        let output = MockOutputManager()
        let exp = expectation(description: "append called with normalized text")
        output.onAppend = { _ in exp.fulfill() }

        let hotkeys = MockHotkeyManager()
        let pipeline = MockAudioPipeline()
        let txr = MockTranscriber(makeTranscriptionResult(text: "git status."))
        let ctrl = SessionController(
            hotkeys: hotkeys,
            pipeline: pipeline,
            transcriber: txr,
            resolver: EgregoreIntentResolver(),
            output: output
        )
        await ctrl.start()

        hotkeys.emit(.toggle)
        try await Task.sleep(nanoseconds: 30_000_000)
        await pipeline.emitSegment(makeSpeechSegment())

        await fulfillment(of: [exp], timeout: 2)
        XCTAssertEqual(output.appended, ["git status"])
    }

    // MARK: Isolated ROGER → send

    func testIsolatedRogerCallsSend() async throws {
        let output = MockOutputManager()
        let exp    = expectation(description: "send called")
        output.onSend = { exp.fulfill() }

        let hotkeys  = MockHotkeyManager()
        let pipeline = MockAudioPipeline()
        let txr = MockTranscriber(makeTranscriptionResult(text: "ROGER",
                                                          silenceBefore: .milliseconds(2000),
                                                          duration: .milliseconds(800),
                                                          trailingSilenceAfter: .milliseconds(900),
                                                          endedBySilence: true))
        let ctrl = SessionController(hotkeys: hotkeys, pipeline: pipeline,
                                     transcriber: txr, resolver: EgregoreIntentResolver(), output: output)
        await ctrl.start()

        hotkeys.emit(.toggle)
        try await Task.sleep(nanoseconds: 30_000_000)
        await pipeline.emitSegment(makeSpeechSegment(silenceBefore: .milliseconds(2000),
                                                     duration: .milliseconds(800),
                                                     trailingSilenceAfter: .milliseconds(900),
                                                     endedBySilence: true))

        await fulfillment(of: [exp], timeout: 2)
        XCTAssertEqual(output.sendCount, 1)
        XCTAssertEqual(output.appended, [])
    }

    // MARK: Isolated ABORT → clear

    func testIsolatedAbortCallsClear() async throws {
        let output = MockOutputManager()
        let exp    = expectation(description: "clear called")
        output.onClear = { exp.fulfill() }

        let hotkeys  = MockHotkeyManager()
        let pipeline = MockAudioPipeline()
        let txr = MockTranscriber(makeTranscriptionResult(text: "ABORT",
                                                          silenceBefore: .milliseconds(2000),
                                                          duration: .milliseconds(800),
                                                          trailingSilenceAfter: .milliseconds(900),
                                                          endedBySilence: true))
        let ctrl = SessionController(hotkeys: hotkeys, pipeline: pipeline,
                                     transcriber: txr, resolver: EgregoreIntentResolver(), output: output)
        await ctrl.start()

        hotkeys.emit(.toggle)
        try await Task.sleep(nanoseconds: 30_000_000)
        await pipeline.emitSegment(makeSpeechSegment(silenceBefore: .milliseconds(2000),
                                                     duration: .milliseconds(800),
                                                     trailingSilenceAfter: .milliseconds(900),
                                                     endedBySilence: true))

        await fulfillment(of: [exp], timeout: 2)
        XCTAssertEqual(output.clearCount, 1)
        XCTAssertEqual(output.appended, [])
    }

    // MARK: Relaxed timing ROGER → send

    func testRelaxedTimingRogerCallsSend() async throws {
        let output = MockOutputManager()
        let exp    = expectation(description: "send called with relaxed timing")
        output.onSend = { exp.fulfill() }

        let hotkeys  = MockHotkeyManager()
        let pipeline = MockAudioPipeline()
        let txr = MockTranscriber(makeTranscriptionResult(text: "ROGER",
                                                          silenceBefore: .milliseconds(200),
                                                          duration: .milliseconds(600),
                                                          trailingSilenceAfter: .milliseconds(100),
                                                          endedBySilence: true))
        let ctrl = SessionController(hotkeys: hotkeys, pipeline: pipeline,
                                     transcriber: txr, resolver: EgregoreIntentResolver(), output: output)
        await ctrl.start()

        hotkeys.emit(.toggle)
        try await Task.sleep(nanoseconds: 30_000_000)
        await pipeline.emitSegment(makeSpeechSegment(silenceBefore: .milliseconds(200),
                                                     duration: .milliseconds(600),
                                                     trailingSilenceAfter: .milliseconds(100),
                                                     endedBySilence: true))

        await fulfillment(of: [exp], timeout: 2)
        XCTAssertEqual(output.sendCount, 1)
        XCTAssertEqual(output.appended, [])
    }

    // MARK: Minimal timing ROGER → send

    func testMinimalTimingRogerCallsSend() async throws {
        let output = MockOutputManager()
        let exp    = expectation(description: "send called with minimal timing")
        output.onSend = { exp.fulfill() }

        let hotkeys  = MockHotkeyManager()
        let pipeline = MockAudioPipeline()
        let txr = MockTranscriber(makeTranscriptionResult(text: "ROGER",
                                                          silenceBefore: .milliseconds(100),
                                                          duration: .milliseconds(600),
                                                          trailingSilenceAfter: .milliseconds(50),
                                                          endedBySilence: true))
        let ctrl = SessionController(hotkeys: hotkeys, pipeline: pipeline,
                                     transcriber: txr, resolver: EgregoreIntentResolver(), output: output)
        await ctrl.start()

        hotkeys.emit(.toggle)
        try await Task.sleep(nanoseconds: 30_000_000)
        await pipeline.emitSegment(makeSpeechSegment(silenceBefore: .milliseconds(100),
                                                     duration: .milliseconds(600),
                                                     trailingSilenceAfter: .milliseconds(50),
                                                     endedBySilence: true))

        await fulfillment(of: [exp], timeout: 2)
        XCTAssertEqual(output.sendCount, 1)
        XCTAssertEqual(output.appended, [])
    }

    // MARK: Minimal timing ABORT → clear

    func testMinimalTimingAbortCallsClear() async throws {
        let output = MockOutputManager()
        let exp    = expectation(description: "clear called with minimal timing")
        output.onClear = { exp.fulfill() }

        let hotkeys  = MockHotkeyManager()
        let pipeline = MockAudioPipeline()
        let txr = MockTranscriber(makeTranscriptionResult(text: "ABORT",
                                                          silenceBefore: .milliseconds(100),
                                                          duration: .milliseconds(500),
                                                          trailingSilenceAfter: .milliseconds(50),
                                                          endedBySilence: true))
        let ctrl = SessionController(hotkeys: hotkeys, pipeline: pipeline,
                                     transcriber: txr, resolver: EgregoreIntentResolver(), output: output)
        await ctrl.start()

        hotkeys.emit(.toggle)
        try await Task.sleep(nanoseconds: 30_000_000)
        await pipeline.emitSegment(makeSpeechSegment(silenceBefore: .milliseconds(100),
                                                     duration: .milliseconds(500),
                                                     trailingSilenceAfter: .milliseconds(50),
                                                     endedBySilence: true))

        await fulfillment(of: [exp], timeout: 2)
        XCTAssertEqual(output.clearCount, 1)
        XCTAssertEqual(output.appended, [])
    }

    // MARK: ROGER in a phrase injects as text, not command

    func testRogerInPhraseInjectsAsText() async throws {
        let output = MockOutputManager()
        let exp    = expectation(description: "append called for ROGER phrase")
        output.onAppend = { _ in exp.fulfill() }

        let hotkeys  = MockHotkeyManager()
        let pipeline = MockAudioPipeline()
        let txr = MockTranscriber(makeTranscriptionResult(text: "ROGER that",
                                                          silenceBefore: .milliseconds(200),
                                                          duration: .milliseconds(2500),
                                                          trailingSilenceAfter: .milliseconds(900),
                                                          endedBySilence: true))
        let ctrl = SessionController(hotkeys: hotkeys, pipeline: pipeline,
                                     transcriber: txr, resolver: EgregoreIntentResolver(), output: output)
        await ctrl.start()

        hotkeys.emit(.toggle)
        try await Task.sleep(nanoseconds: 30_000_000)
        await pipeline.emitSegment(makeSpeechSegment(silenceBefore: .milliseconds(200),
                                                     duration: .milliseconds(2500),
                                                     trailingSilenceAfter: .milliseconds(900),
                                                     endedBySilence: true))

        await fulfillment(of: [exp], timeout: 2)
        XCTAssertEqual(output.appended, ["ROGER that"])
        XCTAssertEqual(output.sendCount, 0)
        XCTAssertEqual(output.clearCount, 0)
    }
}
