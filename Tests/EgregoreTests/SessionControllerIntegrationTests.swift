import XCTest
@testable import Egregore

// MARK: - Test doubles

final class MockHotkeyManager: HotkeyManager, @unchecked Sendable {
    // MARK: Lifecycle

    init() {
        var cont: AsyncStream<HotkeyEvent>.Continuation!
        events = AsyncStream { cont = $0 }
        self.cont = cont!
    }

    // MARK: Internal

    nonisolated let events: AsyncStream<HotkeyEvent>

    func emit(_ event: HotkeyEvent) {
        cont.yield(event)
    }

    // MARK: Private

    private let cont: AsyncStream<HotkeyEvent>.Continuation
}

actor MockAudioPipeline: AudioPipeline {
    // MARK: Lifecycle

    init() {
        var segmentCont: AsyncStream<SpeechSegment>.Continuation!
        segments = AsyncStream { segmentCont = $0 }
        segCont = segmentCont!
        var partialCont: AsyncStream<SpeechCaptureSnapshot>.Continuation!
        captureSnapshots = AsyncStream { partialCont = $0 }
        snapshotCont = partialCont!
    }

    // MARK: Internal

    nonisolated let segments: AsyncStream<SpeechSegment>
    nonisolated let captureSnapshots: AsyncStream<SpeechCaptureSnapshot>
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start() {
        startCount += 1
    }

    func stop() {
        stopCount += 1
    }

    func emitSegment(_ seg: SpeechSegment) {
        segCont.yield(seg)
    }

    func emitSnapshot(_ snapshot: SpeechCaptureSnapshot) {
        snapshotCont.yield(snapshot)
    }

    // MARK: Private

    private let segCont: AsyncStream<SpeechSegment>.Continuation
    private let snapshotCont: AsyncStream<SpeechCaptureSnapshot>.Continuation
}

final class MockTranscriber: Transcriber, @unchecked Sendable {
    // MARK: Lifecycle

    init(_ result: TranscriptionResult) {
        self.result = result
        var cont: AsyncStream<String>.Continuation!
        partialTextStream = AsyncStream { cont = $0 }
        partialContinuation = cont!
    }

    // MARK: Internal

    var result: TranscriptionResult
    var partialText = ""

    nonisolated let partialTextStream: AsyncStream<String>

    func emitPartial(_ text: String) {
        partialContinuation.yield(text)
    }

    func transcribePartial(_ snapshot: SpeechCaptureSnapshot) async -> String {
        partialText
    }

    func transcribe(_ segment: SpeechSegment) async -> TranscriptionResult {
        result
    }

    // MARK: Private

    private let partialContinuation: AsyncStream<String>.Continuation
}

final class MockOutputManager: OutputManager, @unchecked Sendable {
    var isAtPrompt: Bool = true
    private(set) var appended: [String] = []
    private(set) var replaced: [String] = []
    private(set) var sendCount = 0
    private(set) var clearCount = 0
    var appendResult: OutputResult = .success
    var replaceResult: OutputResult = .success
    var sendResult: OutputResult = .success
    var clearResult: OutputResult = .success

    var onAppend: ((String) -> Void)?
    var onReplace: ((String) -> Void)?
    var onSend: (() -> Void)?
    var onClear: (() -> Void)?

    func append(_ text: String) -> OutputResult {
        appended.append(text)
        onAppend?(text)
        return appendResult
    }

    func replace(_ newText: String) -> OutputResult {
        replaced.append(newText)
        onReplace?(newText)
        return replaceResult
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

    func resetKeyboardState() {}
}

// MARK: - Helpers

private func makeSpeechSegment(
    silenceBefore: Duration = .milliseconds(2000),
    duration: Duration = .milliseconds(800),
    trailingSilenceAfter: Duration = .zero,
    endedBySilence: Bool = false
) -> SpeechSegment {
    SpeechSegment(
        audio: [Float](repeating: 0.1, count: 1600),
        silenceBefore: silenceBefore,
        duration: duration,
        trailingSilenceAfter: trailingSilenceAfter,
        endedBySilence: endedBySilence
    )
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
    TranscriptionResult(
        text: text,
        confidence: confidence,
        segment: makeSpeechSegment(
            silenceBefore: silenceBefore,
            duration: duration,
            trailingSilenceAfter: trailingSilenceAfter,
            endedBySilence: endedBySilence
        )
    )
}

// MARK: - Tests

final class SessionControllerIntegrationTests: XCTestCase {
    // MARK: Toggle on → dictation inject

    func testToggleOnDictationPartialsPlaceText() async throws {
        let output = MockOutputManager()
        let exp = expectation(description: "append called via partial")
        output.onAppend = { _ in exp.fulfill() }

        let hotkeys = MockHotkeyManager()
        let pipeline = MockAudioPipeline()
        let txr = MockTranscriber(makeTranscriptionResult(text: "git status"))
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
        txr.emitPartial("git status")

        await fulfillment(of: [exp], timeout: 2)
        XCTAssertEqual(output.appended, ["git status"])
        XCTAssertEqual(output.sendCount, 0)
        XCTAssertEqual(output.clearCount, 0)
    }

    // MARK: Discard is no-op

    func testDictationDiscardIsNoOp() async throws {
        let output = MockOutputManager()
        let exp = expectation(description: "no append")
        exp.isInverted = true
        output.onAppend = { _ in exp.fulfill() }
        output.onSend = { exp.fulfill() }
        output.onClear = { exp.fulfill() }

        let hotkeys = MockHotkeyManager()
        let pipeline = MockAudioPipeline()
        let txr = MockTranscriber(makeTranscriptionResult(text: "noise", confidence: 0.05))
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

        await fulfillment(of: [exp], timeout: 0.5)
        XCTAssertEqual(output.appended, [])
        XCTAssertEqual(output.sendCount, 0)
        XCTAssertEqual(output.clearCount, 0)
    }

    // MARK: Toggle starts and stops pipeline

    func testToggleOnStartsPipeline() async throws {
        let hotkeys = MockHotkeyManager()
        let pipeline = MockAudioPipeline()
        let txr = MockTranscriber(makeTranscriptionResult(text: ""))
        let output = MockOutputManager()
        let ctrl = SessionController(
            hotkeys: hotkeys,
            pipeline: pipeline,
            transcriber: txr,
            resolver: EgregoreIntentResolver(),
            output: output
        )
        await ctrl.start()

        hotkeys.emit(.toggle)
        try await Task.sleep(nanoseconds: 50_000_000)

        let startCount = await pipeline.startCount
        XCTAssertEqual(startCount, 1)
    }

    func testToggleTwiceStopsPipeline() async throws {
        let hotkeys = MockHotkeyManager()
        let pipeline = MockAudioPipeline()
        let txr = MockTranscriber(makeTranscriptionResult(text: ""))
        let output = MockOutputManager()
        let ctrl = SessionController(
            hotkeys: hotkeys,
            pipeline: pipeline,
            transcriber: txr,
            resolver: EgregoreIntentResolver(),
            output: output
        )
        await ctrl.start()

        hotkeys.emit(.toggle)
        hotkeys.emit(.toggle)
        try await Task.sleep(nanoseconds: 100_000_000)

        let stopCount = await pipeline.stopCount
        XCTAssertGreaterThanOrEqual(stopCount, 1)
    }

    // MARK: Normal utterance appends text

    func testNormalUtterancePartialsAppend() async throws {
        let output = MockOutputManager()
        let exp = expectation(description: "append called via partial")
        output.onAppend = { _ in exp.fulfill() }

        let hotkeys = MockHotkeyManager()
        let pipeline = MockAudioPipeline()
        let txr = MockTranscriber(makeTranscriptionResult(
            text: "ls -la",
            silenceBefore: .milliseconds(200),
            duration: .milliseconds(800),
            trailingSilenceAfter: .milliseconds(900),
            endedBySilence: true
        ))
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
        txr.emitPartial("ls -la")

        await fulfillment(of: [exp], timeout: 2)
        XCTAssertEqual(output.appended, ["ls -la"])
    }

    func testPartialNormalizesTrailingPunctuation() async throws {
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
        txr.emitPartial("git status.")

        await fulfillment(of: [exp], timeout: 2)
        XCTAssertEqual(output.appended, ["git status"])
    }

    // MARK: Isolated ROGER → send

    func testIsolatedRogerCallsSend() async throws {
        let output = MockOutputManager()
        let exp = expectation(description: "send called")
        output.onSend = { exp.fulfill() }

        let hotkeys = MockHotkeyManager()
        let pipeline = MockAudioPipeline()
        let txr = MockTranscriber(makeTranscriptionResult(
            text: "ROGER",
            silenceBefore: .milliseconds(2000),
            duration: .milliseconds(800),
            trailingSilenceAfter: .milliseconds(900),
            endedBySilence: true
        ))
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
        await pipeline.emitSegment(makeSpeechSegment(
            silenceBefore: .milliseconds(2000),
            duration: .milliseconds(800),
            trailingSilenceAfter: .milliseconds(900),
            endedBySilence: true
        ))

        await fulfillment(of: [exp], timeout: 2)
        XCTAssertEqual(output.sendCount, 1)
        XCTAssertEqual(output.appended, [])
    }

    // MARK: Isolated ABORT → clear

    func testIsolatedAbortCallsClear() async throws {
        let output = MockOutputManager()
        let exp = expectation(description: "clear called")
        output.onClear = { exp.fulfill() }

        let hotkeys = MockHotkeyManager()
        let pipeline = MockAudioPipeline()
        let txr = MockTranscriber(makeTranscriptionResult(
            text: "ABORT",
            silenceBefore: .milliseconds(2000),
            duration: .milliseconds(800),
            trailingSilenceAfter: .milliseconds(900),
            endedBySilence: true
        ))
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
        await pipeline.emitSegment(makeSpeechSegment(
            silenceBefore: .milliseconds(2000),
            duration: .milliseconds(800),
            trailingSilenceAfter: .milliseconds(900),
            endedBySilence: true
        ))

        await fulfillment(of: [exp], timeout: 2)
        XCTAssertEqual(output.clearCount, 1)
        XCTAssertEqual(output.appended, [])
    }

    // MARK: Relaxed timing ROGER → send

    func testRelaxedTimingRogerCallsSend() async throws {
        let output = MockOutputManager()
        let exp = expectation(description: "send called with relaxed timing")
        output.onSend = { exp.fulfill() }

        let hotkeys = MockHotkeyManager()
        let pipeline = MockAudioPipeline()
        let txr = MockTranscriber(makeTranscriptionResult(
            text: "ROGER",
            silenceBefore: .milliseconds(200),
            duration: .milliseconds(600),
            trailingSilenceAfter: .milliseconds(100),
            endedBySilence: true
        ))
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
        await pipeline.emitSegment(makeSpeechSegment(
            silenceBefore: .milliseconds(200),
            duration: .milliseconds(600),
            trailingSilenceAfter: .milliseconds(100),
            endedBySilence: true
        ))

        await fulfillment(of: [exp], timeout: 2)
        XCTAssertEqual(output.sendCount, 1)
        XCTAssertEqual(output.appended, [])
    }

    // MARK: Minimal timing ROGER → send

    func testMinimalTimingRogerCallsSend() async throws {
        let output = MockOutputManager()
        let exp = expectation(description: "send called with minimal timing")
        output.onSend = { exp.fulfill() }

        let hotkeys = MockHotkeyManager()
        let pipeline = MockAudioPipeline()
        let txr = MockTranscriber(makeTranscriptionResult(
            text: "ROGER",
            silenceBefore: .milliseconds(100),
            duration: .milliseconds(600),
            trailingSilenceAfter: .milliseconds(50),
            endedBySilence: true
        ))
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
        await pipeline.emitSegment(makeSpeechSegment(
            silenceBefore: .milliseconds(100),
            duration: .milliseconds(600),
            trailingSilenceAfter: .milliseconds(50),
            endedBySilence: true
        ))

        await fulfillment(of: [exp], timeout: 2)
        XCTAssertEqual(output.sendCount, 1)
        XCTAssertEqual(output.appended, [])
    }

    // MARK: Minimal timing ABORT → clear

    func testMinimalTimingAbortCallsClear() async throws {
        let output = MockOutputManager()
        let exp = expectation(description: "clear called with minimal timing")
        output.onClear = { exp.fulfill() }

        let hotkeys = MockHotkeyManager()
        let pipeline = MockAudioPipeline()
        let txr = MockTranscriber(makeTranscriptionResult(
            text: "ABORT",
            silenceBefore: .milliseconds(100),
            duration: .milliseconds(500),
            trailingSilenceAfter: .milliseconds(50),
            endedBySilence: true
        ))
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
        await pipeline.emitSegment(makeSpeechSegment(
            silenceBefore: .milliseconds(100),
            duration: .milliseconds(500),
            trailingSilenceAfter: .milliseconds(50),
            endedBySilence: true
        ))

        await fulfillment(of: [exp], timeout: 2)
        XCTAssertEqual(output.clearCount, 1)
        XCTAssertEqual(output.appended, [])
    }

    // MARK: ROGER in a phrase injects as text, not command

    // MARK: Keyboard fallback mode

    func testKeyboardModeSkipsRevision() async throws {
        let output = MockOutputManager()
        output.isAtPrompt = false
        let exp = expectation(description: "first partial appended")
        output.onAppend = { _ in exp.fulfill() }

        let hotkeys = MockHotkeyManager()
        let pipeline = MockAudioPipeline()
        let txr = MockTranscriber(makeTranscriptionResult(text: "git stash"))
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
        txr.emitPartial("git status")
        await fulfillment(of: [exp], timeout: 2)

        // Emit word-level revision — "status" → "stash"
        txr.emitPartial("git stash")
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(output.appended, ["git status"])
        XCTAssertEqual(output.replaced, [], "keyboard mode should never replace during streaming")
    }

    func testKeyboardModeFinalCorrectionOnDispatch() async throws {
        let output = MockOutputManager()
        output.isAtPrompt = false
        let appendExp = expectation(description: "partial appended")
        output.onAppend = { _ in appendExp.fulfill() }

        let hotkeys = MockHotkeyManager()
        let pipeline = MockAudioPipeline()
        let txr = MockTranscriber(makeTranscriptionResult(text: "git stash"))
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
        txr.emitPartial("git status")
        await fulfillment(of: [appendExp], timeout: 2)

        // Final transcription differs from what partials placed
        let replaceExp = expectation(description: "final replace")
        output.onReplace = { _ in replaceExp.fulfill() }
        await pipeline.emitSegment(makeSpeechSegment(
            silenceBefore: .milliseconds(2000),
            trailingSilenceAfter: .milliseconds(900),
            endedBySilence: true
        ))
        await fulfillment(of: [replaceExp], timeout: 2)
        XCTAssertEqual(output.replaced, ["git stash"])
    }

    func testKeyboardModeNoFinalCorrectionWhenMatching() async throws {
        let output = MockOutputManager()
        output.isAtPrompt = false
        let appendExp = expectation(description: "partial appended")
        output.onAppend = { _ in appendExp.fulfill() }

        let hotkeys = MockHotkeyManager()
        let pipeline = MockAudioPipeline()
        let txr = MockTranscriber(makeTranscriptionResult(text: "git status"))
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
        txr.emitPartial("git status")
        await fulfillment(of: [appendExp], timeout: 2)

        // Final transcription matches what partials placed
        let noReplace = expectation(description: "no replace")
        noReplace.isInverted = true
        output.onReplace = { _ in noReplace.fulfill() }
        await pipeline.emitSegment(makeSpeechSegment(
            silenceBefore: .milliseconds(2000),
            trailingSilenceAfter: .milliseconds(900),
            endedBySilence: true
        ))
        await fulfillment(of: [noReplace], timeout: 0.5)
        XCTAssertEqual(output.replaced, [])
    }

    func testNoDoubleSpacingOnPunctuationDelta() async throws {
        let output = MockOutputManager()
        output.isAtPrompt = false
        var appendCount = 0
        let exp = expectation(description: "second append")
        output.onAppend = { _ in
            appendCount += 1
            if appendCount == 2 { exp.fulfill() }
        }

        let hotkeys = MockHotkeyManager()
        let pipeline = MockAudioPipeline()
        let txr = MockTranscriber(makeTranscriptionResult(text: "Hello world, my friend"))
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
        // Normalizer strips trailing comma: "Hello world," → "Hello world"
        txr.emitPartial("Hello world,")
        try await Task.sleep(nanoseconds: 30_000_000)
        // Next partial extends with mid-sentence punctuation
        txr.emitPartial("Hello world, my friend")

        await fulfillment(of: [exp], timeout: 2)
        // Delta should be ", my friend" — no extra space before the comma
        XCTAssertEqual(output.appended, ["Hello world", ", my friend"])
    }

    // MARK: FIFO mode

    func testFifoModeReplacesOnRevision() async throws {
        let output = MockOutputManager()
        output.isAtPrompt = true
        let exp = expectation(description: "replace called")
        output.onReplace = { _ in exp.fulfill() }

        let hotkeys = MockHotkeyManager()
        let pipeline = MockAudioPipeline()
        let txr = MockTranscriber(makeTranscriptionResult(text: "git stash"))
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
        txr.emitPartial("git status")
        try await Task.sleep(nanoseconds: 30_000_000)
        txr.emitPartial("git stash")

        await fulfillment(of: [exp], timeout: 2)
        XCTAssertEqual(output.replaced, ["git stash"])
    }

    func testRogerInPhraseInjectsAsTextViaPartials() async throws {
        let output = MockOutputManager()
        let exp = expectation(description: "append called for ROGER phrase via partial")
        output.onAppend = { _ in exp.fulfill() }

        let hotkeys = MockHotkeyManager()
        let pipeline = MockAudioPipeline()
        let txr = MockTranscriber(makeTranscriptionResult(
            text: "ROGER that",
            silenceBefore: .milliseconds(200),
            duration: .milliseconds(2500),
            trailingSilenceAfter: .milliseconds(900),
            endedBySilence: true
        ))
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
        txr.emitPartial("ROGER that")

        await fulfillment(of: [exp], timeout: 2)
        XCTAssertEqual(output.appended, ["ROGER that"])
        XCTAssertEqual(output.sendCount, 0)
        XCTAssertEqual(output.clearCount, 0)
    }
}
