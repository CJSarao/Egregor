import XCTest
import Darwin
@testable import Egregore

// MARK: - Property-Based: IntentResolver

final class IntentResolverPropertyTests: XCTestCase {
    // MARK: Internal

    let resolver = EgregoreIntentResolver()
    let iterations = 200

    // MARK: Isolated vocabulary + sufficient confidence → .command

    func testVocabularyWithIsolationTimingAlwaysResolvesToCommand() throws {
        let vocabulary = ["ROGER", "roger", "Roger", "ABORT", "abort", "Abort"]
        for _ in 0 ..< iterations {
            let word = try XCTUnwrap(vocabulary.randomElement())
            let confidence = Float.random(in: 0.3 ... 1.0)
            let (silence, dur, trailingSilence, endedBySilence) = randomIsolatedTiming()
            let result = makeResult(
                text: word,
                confidence: confidence,
                silence: silence,
                duration: dur,
                trailingSilence: trailingSilence,
                endedBySilence: endedBySilence
            )

            let intent = resolver.resolve(result)
            guard case .command = intent else {
                XCTFail(
                    "Vocabulary '\(word)' with isolated timing must resolve to .command, got \(intent) (silence=\(silence), dur=\(dur), conf=\(confidence))"
                )
                return
            }
        }
    }

    // MARK: Non-vocabulary NEVER produces .command regardless of timing

    func testNonVocabularyNeverResolvesToCommand() {
        for _ in 0 ..< iterations {
            let text = randomNonVocabularyText()
            let confidence = Float.random(in: 0.3 ... 1.0)
            let (silence, dur, trailingSilence, endedBySilence) = randomIsolatedTiming()
            let result = makeResult(
                text: text,
                confidence: confidence,
                silence: silence,
                duration: dur,
                trailingSilence: trailingSilence,
                endedBySilence: endedBySilence
            )

            let intent = resolver.resolve(result)
            if case .command = intent {
                XCTFail("Non-vocabulary '\(text)' must never resolve to .command")
            }
        }
    }

    // MARK: Low confidence → .discard regardless of text or timing

    func testLowConfidenceAlwaysDiscards() throws {
        let allTexts = ["ROGER", "ABORT", "hello", "git status", "roger", "abort"]
        for _ in 0 ..< iterations {
            let text = try XCTUnwrap(allTexts.randomElement())
            let confidence = Float.random(in: 0.0 ... 0.2999)
            let silence = Duration.milliseconds(Int.random(in: 0 ... 5000))
            let dur = Duration.milliseconds(Int.random(in: 50 ... 5000))
            let result = makeResult(text: text, confidence: confidence, silence: silence, duration: dur)

            XCTAssertEqual(
                resolver.resolve(result), .discard,
                "Confidence \(confidence) must always discard, text='\(text)'"
            )
        }
    }

    // MARK: Vocabulary without isolation timing → .inject (not .command)

    func testVocabularyWithoutIsolationInjects() throws {
        let vocabulary = ["ROGER", "ABORT"]
        for _ in 0 ..< iterations {
            let word = try XCTUnwrap(vocabulary.randomElement())
            let confidence = Float.random(in: 0.3 ... 1.0)
            let (silence, dur, trailingSilence, endedBySilence) = randomNonIsolatedTiming()
            let result = makeResult(
                text: word,
                confidence: confidence,
                silence: silence,
                duration: dur,
                trailingSilence: trailingSilence,
                endedBySilence: endedBySilence
            )

            let intent = resolver.resolve(result)
            XCTAssertEqual(
                intent, .inject(word),
                "Vocabulary '\(word)' without isolation must inject (silence=\(silence), dur=\(dur))"
            )
        }
    }

    // MARK: Private

    // MARK: Helpers

    private func randomIsolatedTiming() -> (silence: Duration, duration: Duration, trailingSilence: Duration, endedBySilence: Bool) {
        let silence = Duration.milliseconds(Int.random(in: 1501 ... 5000))
        let dur = Duration.milliseconds(Int.random(in: 50 ... 1999))
        let trailingSilence = Duration.milliseconds(Int.random(in: 800 ... 1600))
        return (silence, dur, trailingSilence, true)
    }

    private func randomNonIsolatedTiming() -> (silence: Duration, duration: Duration, trailingSilence: Duration, endedBySilence: Bool) {
        switch Int.random(in: 0 ... 1) {
        case 0:
            (
                .milliseconds(Int.random(in: 0 ... 5000)),
                .milliseconds(Int.random(in: 50 ... 5000)),
                .milliseconds(Int.random(in: 0 ... 1600)),
                false
            )

        default:
            (
                .milliseconds(Int.random(in: 0 ... 5000)),
                .milliseconds(Int.random(in: 2000 ... 5000)),
                .milliseconds(Int.random(in: 0 ... 1600)),
                Bool.random()
            )
        }
    }

    private func randomNonVocabularyText() -> String {
        let words = [
            "git",
            "status",
            "hello",
            "world",
            "ls",
            "cd",
            "npm",
            "run",
            "test",
            "echo",
            "cat",
            "deploy",
            "build",
            "ROGER that",
            "say ABORT",
            "ABORTED",
            "roger wilco",
            "abort mission",
            "go",
            "stop",
            "clear",
            "send",
        ]
        let count = Int.random(in: 1 ... 3)
        return (0 ..< count).map { _ in words.randomElement()! }.joined(separator: " ")
    }

    private func makeResult(
        text: String,
        confidence: Float,
        silence: Duration,
        duration: Duration,
        trailingSilence: Duration = .milliseconds(800),
        endedBySilence: Bool = true
    ) -> TranscriptionResult {
        TranscriptionResult(
            text: text,
            confidence: confidence,
            segment: SpeechSegment(
                audio: [],
                silenceBefore: silence,
                duration: duration,
                trailingSilenceAfter: trailingSilence,
                endedBySilence: endedBySilence
            )
        )
    }
}

// MARK: - Property-Based: OutputManager Buffer Semantics

final class OutputManagerPropertyTests: XCTestCase {
    // MARK: Internal

    func testAppendSequenceFollowedByClearAlwaysEndsClear() {
        let (path, fd) = makePipe()
        defer { Darwin.close(fd)
            Darwin.unlink(path)
        }

        let manager = ShellOutputManager { path }
        let count = Int.random(in: 1 ... 20)
        for i in 0 ..< count {
            manager.append("word\(i)")
        }
        manager.clear()

        let messages = parseMessages(readAll(fd: fd))
        XCTAssertEqual(messages.last, "clear|", "Last message must be clear| after \(count) appends + clear")
        XCTAssertEqual(messages.count, count + 1)
    }

    func testMultipleAppendsProduceOrderedInjectMessages() {
        let (path, fd) = makePipe()
        defer { Darwin.close(fd)
            Darwin.unlink(path)
        }

        let manager = ShellOutputManager { path }
        let words = (0 ..< Int.random(in: 2 ... 15)).map { "text_\($0)_\(UInt16.random(in: 0 ... 9999))" }
        for word in words {
            manager.append(word)
        }

        let messages = parseMessages(readAll(fd: fd))
        let expected = words.map { "inject|\($0)" }
        XCTAssertEqual(messages, expected)
    }

    func testUnicodeContentSurvivesPipeRoundTrip() {
        let (path, fd) = makePipe()
        defer { Darwin.close(fd)
            Darwin.unlink(path)
        }

        let manager = ShellOutputManager { path }
        let unicodeTexts = ["café ☕", "日本語テスト", "emoji 🎉🔥", "path/to/файл", "∑∏∫≈"]
        for text in unicodeTexts {
            manager.append(text)
        }

        let messages = parseMessages(readAll(fd: fd))
        let expected = unicodeTexts.map { "inject|\($0)" }
        XCTAssertEqual(messages, expected)
    }

    // MARK: Private

    private func makePipe() -> (path: String, fd: Int32) {
        let path = "/tmp/egregore-prop-\(getpid())-\(UInt32.random(in: 0 ..< UInt32.max)).pipe"
        Darwin.mkfifo(path, 0o600)
        let fd = Darwin.open(path, O_RDWR)
        precondition(fd >= 0, "Failed to open test FIFO at \(path)")
        return (path, fd)
    }

    private func readAll(fd: Int32) -> String {
        var buffer = [UInt8](repeating: 0, count: 65536)
        let n = Darwin.read(fd, &buffer, 65535)
        return n > 0 ? String(bytes: Array(buffer.prefix(n)), encoding: .utf8) ?? "" : ""
    }

    private func parseMessages(_ raw: String) -> [String] {
        raw.components(separatedBy: "\n").filter { !$0.isEmpty }
    }
}

// MARK: - End-to-End: Transcriber → Resolver → Output

final class SpecEndToEndTests: XCTestCase {
    // MARK: Internal

    // MARK: Transcriber produces text from synthesized audio

    func testTranscriberReturnsTextFromSynthesizedInput() async {
        let segment = makeSegment()
        let transcriber = WhisperKitTranscriber {
            { _, _ in ("synthesized text", [-0.2]) }
        }

        let result = await transcriber.transcribe(segment)

        XCTAssertEqual(result.text, "synthesized text")
        XCTAssertGreaterThan(result.confidence, 0.3)
        XCTAssertEqual(result.segment.silenceBefore, segment.silenceBefore)
        XCTAssertEqual(result.segment.duration, segment.duration)
        XCTAssertEqual(result.segment.trailingSilenceAfter, segment.trailingSilenceAfter)
        XCTAssertEqual(result.segment.endedBySilence, segment.endedBySilence)
    }

    // MARK: IntentResolver all branches

    func testResolverDictationInject() {
        let resolver = EgregoreIntentResolver()
        let segment = makeSegment(silenceBefore: .milliseconds(100))
        let result = TranscriptionResult(text: "npm install", confidence: 0.9, segment: segment)
        XCTAssertEqual(resolver.resolve(result), .inject("npm install"))
    }

    func testResolverDictationIsolatedRoger() {
        let resolver = EgregoreIntentResolver()
        let segment = makeSegment(
            silenceBefore: .milliseconds(2000),
            duration: .milliseconds(500),
            trailingSilenceAfter: .milliseconds(900),
            endedBySilence: true
        )
        let result = TranscriptionResult(text: "ROGER", confidence: 0.9, segment: segment)
        XCTAssertEqual(resolver.resolve(result), .command(.roger))
    }

    func testResolverDictationIsolatedAbort() {
        let resolver = EgregoreIntentResolver()
        let segment = makeSegment(
            silenceBefore: .milliseconds(2000),
            duration: .milliseconds(500),
            trailingSilenceAfter: .milliseconds(900),
            endedBySilence: true
        )
        let result = TranscriptionResult(text: "ABORT", confidence: 0.9, segment: segment)
        XCTAssertEqual(resolver.resolve(result), .command(.abort))
    }

    func testResolverDiscardsLowConfidence() {
        let resolver = EgregoreIntentResolver()
        let segment = makeSegment()
        let result = TranscriptionResult(text: "ROGER", confidence: 0.1, segment: segment)
        XCTAssertEqual(resolver.resolve(result), .discard)
    }

    // MARK: Intent → OutputManager pipe writes

    func testInjectIntentProducesCorrectPipeWrite() {
        let (path, fd) = makePipeForE2E()
        defer { Darwin.close(fd)
            Darwin.unlink(path)
        }

        let output = ShellOutputManager { path }
        output.append("echo hello")

        XCTAssertEqual(readPipe(fd: fd), "inject|echo hello\n")
    }

    func testClearIntentProducesCorrectPipeWrite() {
        let (path, fd) = makePipeForE2E()
        defer { Darwin.close(fd)
            Darwin.unlink(path)
        }

        let output = ShellOutputManager { path }
        output.clear()

        XCTAssertEqual(readPipe(fd: fd), "clear|\n")
    }

    func testAppendThenSendSequenceWritesBothPipeMessages() {
        let (path, fd) = makePipeForE2E()
        defer { Darwin.close(fd)
            Darwin.unlink(path)
        }

        let output = ShellOutputManager { path }
        output.append("ls -la")
        output.send()

        XCTAssertEqual(readPipe(fd: fd), "inject|ls -la\nsend|\n")
    }

    // MARK: Full mocked pipeline: toggle → segment → transcribe → resolve → output

    func testFullPipelineDictationInject() async throws {
        let output = MockOutputManager()
        let exp = expectation(description: "inject via full pipeline")
        output.onAppend = { _ in exp.fulfill() }

        let hotkeys = MockHotkeyManager()
        let pipeline = MockAudioPipeline()
        let txr = MockTranscriber(
            TranscriptionResult(
                text: "git log",
                confidence: 0.95,
                segment: makeSegment(silenceBefore: .milliseconds(200))
            )
        )
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
        await pipeline.emitSegment(makeSegment(silenceBefore: .milliseconds(200)))

        await fulfillment(of: [exp], timeout: 2)
        XCTAssertEqual(output.appended, ["git log"])
        XCTAssertEqual(output.sendCount, 0)
        XCTAssertEqual(output.clearCount, 0)
    }

    func testFullPipelineLowConfidenceDiscardsEverything() async throws {
        let output = MockOutputManager()
        let exp = expectation(description: "no output action")
        exp.isInverted = true
        output.onAppend = { _ in exp.fulfill() }
        output.onSend = { exp.fulfill() }
        output.onClear = { exp.fulfill() }

        let hotkeys = MockHotkeyManager()
        let pipeline = MockAudioPipeline()
        let txr = MockTranscriber(
            TranscriptionResult(text: "ROGER", confidence: 0.1, segment: makeSegment())
        )
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
        await pipeline.emitSegment(makeSegment())

        await fulfillment(of: [exp], timeout: 0.5)
        XCTAssertEqual(output.appended, [])
        XCTAssertEqual(output.sendCount, 0)
        XCTAssertEqual(output.clearCount, 0)
    }

    func testFullPipelineIsolatedCommandSendsReturn() async throws {
        let output = MockOutputManager()
        let exp = expectation(description: "send")
        output.onSend = { exp.fulfill() }

        let hotkeys = MockHotkeyManager()
        let pipeline = MockAudioPipeline()
        let txr = MockTranscriber(
            TranscriptionResult(
                text: "ROGER",
                confidence: 0.9,
                segment: makeSegment(
                    silenceBefore: .milliseconds(2000),
                    duration: .milliseconds(800),
                    trailingSilenceAfter: .milliseconds(900),
                    endedBySilence: true
                )
            )
        )
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
        await pipeline.emitSegment(makeSegment(
            silenceBefore: .milliseconds(2000),
            duration: .milliseconds(800),
            trailingSilenceAfter: .milliseconds(900),
            endedBySilence: true
        ))

        await fulfillment(of: [exp], timeout: 2)
        XCTAssertEqual(output.sendCount, 1)
        XCTAssertEqual(output.appended, [])
    }

    func testFullPipelineNormalUtteranceAppends() async throws {
        let output = MockOutputManager()
        let exp = expectation(description: "append")
        output.onAppend = { _ in exp.fulfill() }

        let hotkeys = MockHotkeyManager()
        let pipeline = MockAudioPipeline()
        let txr = MockTranscriber(
            TranscriptionResult(
                text: "docker ps",
                confidence: 0.85,
                segment: makeSegment(
                    silenceBefore: .milliseconds(200),
                    duration: .milliseconds(1500),
                    trailingSilenceAfter: .milliseconds(900),
                    endedBySilence: true
                )
            )
        )
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
        await pipeline.emitSegment(makeSegment(
            silenceBefore: .milliseconds(200),
            duration: .milliseconds(1500),
            trailingSilenceAfter: .milliseconds(900),
            endedBySilence: true
        ))

        await fulfillment(of: [exp], timeout: 2)
        XCTAssertEqual(output.appended, ["docker ps"])
    }

    // MARK: Multi-segment pipeline: append + append + ROGER

    func testFullPipelineMultiSegmentAppendThenSend() async throws {
        let output = MockOutputManager()
        let sendExp = expectation(description: "send after two appends")
        output.onSend = { sendExp.fulfill() }

        let hotkeys = MockHotkeyManager()
        let pipeline = MockAudioPipeline()

        let results: [TranscriptionResult] = [
            TranscriptionResult(
                text: "git",
                confidence: 0.9,
                segment: makeSegment(silenceBefore: .milliseconds(200))
            ),
            TranscriptionResult(
                text: "status",
                confidence: 0.9,
                segment: makeSegment(silenceBefore: .milliseconds(200))
            ),
            TranscriptionResult(
                text: "ROGER",
                confidence: 0.9,
                segment: makeSegment(
                    silenceBefore: .milliseconds(2000),
                    duration: .milliseconds(500),
                    trailingSilenceAfter: .milliseconds(900),
                    endedBySilence: true
                )
            ),
        ]

        let txr = SequentialMockTranscriber(results: results)
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

        await pipeline.emitSegment(makeSegment(silenceBefore: .milliseconds(200)))
        try await Task.sleep(nanoseconds: 50_000_000)
        await pipeline.emitSegment(makeSegment(silenceBefore: .milliseconds(200)))
        try await Task.sleep(nanoseconds: 50_000_000)
        await pipeline.emitSegment(makeSegment(
            silenceBefore: .milliseconds(2000),
            duration: .milliseconds(500),
            trailingSilenceAfter: .milliseconds(900),
            endedBySilence: true
        ))

        await fulfillment(of: [sendExp], timeout: 3)
        XCTAssertEqual(output.appended, ["git", "status"])
        XCTAssertEqual(output.sendCount, 1)
    }

    func testFullPipelineAppendAbortAppendRogerSequence() async throws {
        let output = MockOutputManager()
        let sendExp = expectation(description: "send after clear and re-append")
        output.onSend = { sendExp.fulfill() }

        let hotkeys = MockHotkeyManager()
        let pipeline = MockAudioPipeline()
        let results: [TranscriptionResult] = [
            TranscriptionResult(
                text: "git status",
                confidence: 0.9,
                segment: makeSegment(
                    silenceBefore: .milliseconds(200),
                    duration: .milliseconds(900),
                    trailingSilenceAfter: .milliseconds(900),
                    endedBySilence: true
                )
            ),
            TranscriptionResult(
                text: "ABORT",
                confidence: 0.9,
                segment: makeSegment(
                    silenceBefore: .milliseconds(2000),
                    duration: .milliseconds(500),
                    trailingSilenceAfter: .milliseconds(900),
                    endedBySilence: true
                )
            ),
            TranscriptionResult(
                text: "git diff",
                confidence: 0.9,
                segment: makeSegment(
                    silenceBefore: .milliseconds(200),
                    duration: .milliseconds(900),
                    trailingSilenceAfter: .milliseconds(900),
                    endedBySilence: true
                )
            ),
            TranscriptionResult(
                text: "ROGER",
                confidence: 0.9,
                segment: makeSegment(
                    silenceBefore: .milliseconds(2000),
                    duration: .milliseconds(500),
                    trailingSilenceAfter: .milliseconds(900),
                    endedBySilence: true
                )
            ),
        ]

        let txr = SequentialMockTranscriber(results: results)
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

        await pipeline.emitSegment(makeSegment(
            silenceBefore: .milliseconds(200),
            duration: .milliseconds(900),
            trailingSilenceAfter: .milliseconds(900),
            endedBySilence: true
        ))
        try await Task.sleep(nanoseconds: 50_000_000)
        await pipeline.emitSegment(makeSegment(
            silenceBefore: .milliseconds(2000),
            duration: .milliseconds(500),
            trailingSilenceAfter: .milliseconds(900),
            endedBySilence: true
        ))
        try await Task.sleep(nanoseconds: 50_000_000)
        await pipeline.emitSegment(makeSegment(
            silenceBefore: .milliseconds(200),
            duration: .milliseconds(900),
            trailingSilenceAfter: .milliseconds(900),
            endedBySilence: true
        ))
        try await Task.sleep(nanoseconds: 50_000_000)
        await pipeline.emitSegment(makeSegment(
            silenceBefore: .milliseconds(2000),
            duration: .milliseconds(500),
            trailingSilenceAfter: .milliseconds(900),
            endedBySilence: true
        ))

        await fulfillment(of: [sendExp], timeout: 3)
        XCTAssertEqual(output.appended, ["git status", "git diff"])
        XCTAssertEqual(output.clearCount, 1)
        XCTAssertEqual(output.sendCount, 1)
    }

    // MARK: Private

    // MARK: Helpers

    private func makeSegment(
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

    // MARK: Pipe helpers

    private func makePipeForE2E() -> (path: String, fd: Int32) {
        let path = "/tmp/egregore-e2e-\(getpid())-\(UInt32.random(in: 0 ..< UInt32.max)).pipe"
        Darwin.mkfifo(path, 0o600)
        let fd = Darwin.open(path, O_RDWR)
        precondition(fd >= 0, "Failed to open test FIFO")
        return (path, fd)
    }

    private func readPipe(fd: Int32) -> String {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let n = Darwin.read(fd, &buffer, 4095)
        return n > 0 ? String(bytes: Array(buffer.prefix(n)), encoding: .utf8) ?? "" : ""
    }
}

// MARK: - Sequential mock transcriber for multi-segment E2E tests

final class SequentialMockTranscriber: Transcriber, @unchecked Sendable {
    // MARK: Lifecycle

    init(results: [TranscriptionResult]) {
        self.results = results
        var cont: AsyncStream<String>.Continuation!
        partialTextStream = AsyncStream { cont = $0 }
        partialContinuation = cont!
    }

    // MARK: Internal

    nonisolated let partialTextStream: AsyncStream<String>

    func transcribePartial(_ snapshot: SpeechCaptureSnapshot) async -> String {
        ""
    }

    func transcribe(_ segment: SpeechSegment) async -> TranscriptionResult {
        let r = results[min(index, results.count - 1)]
        index += 1
        return r
    }

    // MARK: Private

    private var results: [TranscriptionResult]
    private var index = 0

    private let partialContinuation: AsyncStream<String>.Continuation
}
