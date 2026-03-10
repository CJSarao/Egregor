import Foundation
import XCTest
@testable import Egregore

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

final class WhisperKitTranscriberTests: XCTestCase {
    private var logDir: URL!
    private var logFile: URL!

    private func readLog() -> String {
        (try? String(contentsOf: logFile, encoding: .utf8)) ?? ""
    }

    override func setUp() {
        super.setUp()
        logDir = FileManager.default.temporaryDirectory
            .appending(path: "egregore-transcriber-logs-\(UUID().uuidString)")
        logFile = logDir.appending(path: "egregore.log")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: logDir)
        super.tearDown()
    }

    // MARK: - confidence(from:)

    func testConfidenceEmptyReturnsZero() {
        XCTAssertEqual(WhisperKitTranscriber.confidence(from: []), 0)
    }

    func testConfidenceZeroAvgLogprobIsOne() {
        XCTAssertEqual(WhisperKitTranscriber.confidence(from: [0.0]), 1.0, accuracy: 1e-6)
    }

    func testConfidenceNegativeAvgLogprobIsExpOfMean() {
        let logprobs: [Float] = [-1.0, -2.0]
        let expected = Foundation.exp((-1.0 + -2.0) / 2.0 as Float)
        XCTAssertEqual(WhisperKitTranscriber.confidence(from: logprobs), expected, accuracy: 1e-5)
    }

    func testConfidenceClampedToZeroForLargeNegative() {
        // exp(-1000) underflows to 0
        let confidence = WhisperKitTranscriber.confidence(from: [-1000.0])
        XCTAssertEqual(confidence, 0, accuracy: 1e-10)
    }

    func testConfidenceClampedToOneForPositive() {
        // Positive avgLogprob should be clamped at 1.0
        XCTAssertEqual(WhisperKitTranscriber.confidence(from: [10.0]), 1.0, accuracy: 1e-6)
    }

    // MARK: - transcribe() with injected engine

    func testTranscribeReturnsTextAndConfidenceFromEngine() async {
        let segment = SpeechSegment(audio: [], silenceBefore: .zero, duration: .zero)
        let transcriber = WhisperKitTranscriber(engineProvider: {
            { _, _ in ("hello world", [-0.5]) }
        })

        let result = await transcriber.transcribe(segment)

        XCTAssertEqual(result.text, "hello world")
        let expectedConfidence = Foundation.exp(-0.5 as Float)
        XCTAssertEqual(result.confidence, expectedConfidence, accuracy: 1e-5)
        XCTAssertEqual(result.segment.audio, segment.audio)
    }

    func testTranscribeEngineFailureReturnsEmptyDiscard() async {
        struct TestError: Error {}
        let segment = SpeechSegment(audio: [0.1, 0.2], silenceBefore: .zero, duration: .zero)
        let transcriber = WhisperKitTranscriber(engineProvider: {
            { _, _ in throw TestError() }
        })

        let result = await transcriber.transcribe(segment)

        XCTAssertEqual(result.text, "")
        XCTAssertEqual(result.confidence, 0)
    }

    func testTranscribeEngineIsLoadedOnlyOnce() async {
        let counter = Counter()
        let segment = SpeechSegment(audio: [], silenceBefore: .zero, duration: .zero)
        let transcriber = WhisperKitTranscriber(engineProvider: {
            await counter.increment()
            return { _, _ in ("text", [0.0]) }
        })

        _ = await transcriber.transcribe(segment)
        _ = await transcriber.transcribe(segment)

        let count = await counter.value
        XCTAssertEqual(count, 1)
    }

    func testTranscribeTrimsWhitespace() async {
        let segment = SpeechSegment(audio: [], silenceBefore: .zero, duration: .zero)
        let transcriber = WhisperKitTranscriber(engineProvider: {
            { _, _ in ("  trimmed  ", [0.0]) }
        })

        let result = await transcriber.transcribe(segment)

        XCTAssertEqual(result.text, "trimmed")
    }

    func testPartialTranscribeReturnsTrimmedText() async {
        let snapshot = SpeechCaptureSnapshot(audio: [0.1, 0.2], duration: .milliseconds(300))
        let logger = RuntimeLogger(fileURL: logFile)
        let transcriber = WhisperKitTranscriber(engineProvider: {
            { _, _ in ("  partial text  ", [0.0]) }
        }, logger: logger)

        let result = await transcriber.transcribePartial(snapshot)

        XCTAssertEqual(result, "partial text")
        let contents = readLog()
        XCTAssertTrue(contents.contains("chars=12"))
        XCTAssertFalse(contents.contains("partial text"))
    }

    func testTranscribeCarriesSegmentMetadata() async {
        let audio: [Float] = [0.1, 0.2, 0.3]
        let silence = Duration.milliseconds(2000)
        let duration = Duration.milliseconds(500)
        let segment = SpeechSegment(audio: audio, silenceBefore: silence, duration: duration)
        let transcriber = WhisperKitTranscriber(engineProvider: {
            { _, _ in ("ok", [0.0]) }
        })

        let result = await transcriber.transcribe(segment)

        XCTAssertEqual(result.segment.silenceBefore, silence)
        XCTAssertEqual(result.segment.duration, duration)
        XCTAssertEqual(result.segment.audio, audio)
    }

    // MARK: - Static configuration

    func testModelVariantIsLargeV3Turbo() {
        XCTAssertEqual(WhisperKitTranscriber.modelVariant, "openai_whisper-large-v3_turbo")
    }

    func testModelStorageURLIsUnderDotLocal() {
        let url = WhisperKitTranscriber.modelStorageURL
        XCTAssertTrue(url.path.contains(".local/share/egregore/models"))
    }
}
