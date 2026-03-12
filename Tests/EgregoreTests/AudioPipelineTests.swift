import XCTest
@testable import Egregore

// Tests use processChunk(_:) directly (internal actor method, no hardware needed).
// Each await pipeline.processChunk(...) runs to completion on the actor before
// returning, so emitted segments are buffered in segments stream by the time
// we call iter.next(). No sleep or timeout required.

final class AudioPipelineTests: XCTestCase {

    private static let SR = AVAudioEnginePipeline.outputSampleRate

    // MARK: - Helpers

    private func makePipeline() -> AVAudioEnginePipeline {
        AVAudioEnginePipeline(tapInstaller: { _ in .init(start: {}, stop: {}) })
    }

    // 512 samples at 0.1 amplitude — RMS = 0.1, well above silenceRMSThreshold
    private func speechChunk(_ n: Int = 512) -> [Float] { [Float](repeating: 0.1, count: n) }

    // 512 samples at 0.0 — RMS = 0.0, below threshold
    private func silenceChunk(_ n: Int = 512) -> [Float] { [Float](repeating: 0.0, count: n) }

    private func speechChunksToMeetMinimum() -> Int {
        let min = AVAudioEnginePipeline.minimumSpeechSamples
        return (min / 512) + 1   // enough chunks so total > minimum
    }

    private func silenceChunksToTriggerVAD() -> Int {
        let threshold = AVAudioEnginePipeline.silenceSamplesThreshold
        return (threshold / 512) + 1
    }

    // MARK: - computeRMS

    func testComputeRMSOfEmptyIsZero() {
        XCTAssertEqual(AVAudioEnginePipeline.computeRMS([]), 0)
    }

    func testComputeRMSOfZeroesIsZero() {
        XCTAssertEqual(AVAudioEnginePipeline.computeRMS([0, 0, 0]), 0)
    }

    func testComputeRMSOfConstantSignal() {
        // RMS of [0.3, 0.3, 0.3] = 0.3
        XCTAssertEqual(AVAudioEnginePipeline.computeRMS([0.3, 0.3, 0.3]), 0.3, accuracy: 1e-6)
    }

    func testComputeRMSMixedAmplitudes() {
        // RMS of [1, -1] = sqrt((1+1)/2) = 1.0
        XCTAssertEqual(AVAudioEnginePipeline.computeRMS([1.0, -1.0]), 1.0, accuracy: 1e-6)
    }

    // MARK: - VAD self-termination (OPEN mode behaviour)

    func testSpeechFollowedBySilenceEmitsOneSegment() async {
        let pipeline = makePipeline()
        var iter = pipeline.segments.makeAsyncIterator()

        let speechCount   = speechChunksToMeetMinimum()
        let silenceCount  = silenceChunksToTriggerVAD()

        for _ in 0..<speechCount  { await pipeline.processChunk(speechChunk()) }
        for _ in 0..<silenceCount { await pipeline.processChunk(silenceChunk()) }

        let segment = await iter.next()
        XCTAssertNotNil(segment)
        XCTAssertNotNil(segment)
        XCTAssertGreaterThanOrEqual(segment!.trailingSilenceAfter, .milliseconds(800))
        XCTAssertEqual(segment?.endedBySilence, true)
    }

    func testSilenceOnlyNeverEmitsSegment() async {
        let pipeline = makePipeline()
        for _ in 0..<50 { await pipeline.processChunk(silenceChunk()) }
        // Stream has no buffered segments — next() would block forever.
        // Verify by draining the buffer with a short-lived task.
        var count = 0
        let task = Task {
            for await _ in pipeline.segments { count += 1 }
        }
        try? await Task.sleep(for: .milliseconds(30))
        task.cancel()
        XCTAssertEqual(count, 0)
    }

    // MARK: - forceEnd (PTT release)

    func testForceEndEmitsCurrentSpeechBuffer() async {
        let pipeline = makePipeline()
        var iter = pipeline.segments.makeAsyncIterator()

        for _ in 0..<speechChunksToMeetMinimum() { await pipeline.processChunk(speechChunk()) }
        await pipeline.forceEnd()

        let segment = await iter.next()
        XCTAssertNotNil(segment)
        XCTAssertEqual(segment?.endedBySilence, false)
    }

    func testForceEndWithNoSpeechEmitsNothing() async {
        let pipeline = makePipeline()
        await pipeline.forceEnd()

        var count = 0
        let task = Task {
            for await _ in pipeline.segments { count += 1 }
        }
        try? await Task.sleep(for: .milliseconds(30))
        task.cancel()
        XCTAssertEqual(count, 0)
    }

    // MARK: - Minimum speech duration

    func testShortSpeechBelowMinimumIsDiscarded() async {
        let pipeline = makePipeline()
        // Inject fewer samples than minimumSpeechSamples
        let shortChunk = speechChunk(AVAudioEnginePipeline.minimumSpeechSamples - 1)
        await pipeline.processChunk(shortChunk)
        await pipeline.forceEnd()

        var count = 0
        let task = Task {
            for await _ in pipeline.segments { count += 1 }
        }
        try? await Task.sleep(for: .milliseconds(30))
        task.cancel()
        XCTAssertEqual(count, 0)
    }

    // MARK: - Duration and silenceBefore accuracy

    func testSegmentDurationMatchesSampleCount() async {
        let pipeline = makePipeline()
        var iter = pipeline.segments.makeAsyncIterator()

        let n = speechChunksToMeetMinimum()
        for _ in 0..<n { await pipeline.processChunk(speechChunk()) }
        await pipeline.forceEnd()

        let segment = await iter.next()!
        let expectedSamples = n * 512
        let expected = Duration.seconds(Double(expectedSamples) / Self.SR)
        XCTAssertEqual(segment.duration, expected)
        XCTAssertEqual(segment.endedBySilence, false)
    }

    func testSilenceBeforeReflectsIdleSamplesBeforeSpeech() async {
        let pipeline = makePipeline()
        var iter = pipeline.segments.makeAsyncIterator()

        let idleSamples = 3_200   // 200 ms at 16 kHz
        await pipeline.processChunk(silenceChunk(idleSamples))
        for _ in 0..<speechChunksToMeetMinimum() { await pipeline.processChunk(speechChunk()) }
        await pipeline.forceEnd()

        let segment = await iter.next()!
        let expected = Duration.seconds(Double(idleSamples) / Self.SR)
        XCTAssertEqual(segment.silenceBefore, expected)
        XCTAssertEqual(segment.trailingSilenceAfter, .zero)
    }

    // MARK: - stop() emits in-progress speech

    func testStopEmitsSpeechInProgress() async {
        let pipeline = makePipeline()
        var iter = pipeline.segments.makeAsyncIterator()

        for _ in 0..<speechChunksToMeetMinimum() { await pipeline.processChunk(speechChunk()) }
        await pipeline.stop()

        let segment = await iter.next()
        XCTAssertNotNil(segment)
    }

    func testStopWithNoSpeechEmitsNothing() async {
        let pipeline = makePipeline()
        await pipeline.stop()

        var count = 0
        let task = Task {
            for await _ in pipeline.segments { count += 1 }
        }
        try? await Task.sleep(for: .milliseconds(30))
        task.cancel()
        XCTAssertEqual(count, 0)
    }

    // MARK: - Multiple segments

    func testMultipleSpeechSegmentsEmittedInOrder() async {
        let pipeline = makePipeline()
        var iter = pipeline.segments.makeAsyncIterator()

        let sc = speechChunksToMeetMinimum()
        let vc = silenceChunksToTriggerVAD()

        for _ in 0..<sc { await pipeline.processChunk(speechChunk()) }
        for _ in 0..<vc { await pipeline.processChunk(silenceChunk()) }
        for _ in 0..<sc { await pipeline.processChunk(speechChunk()) }
        for _ in 0..<vc { await pipeline.processChunk(silenceChunk()) }

        let first  = await iter.next()
        let second = await iter.next()
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
    }

    func testSilenceBeforeSecondSegmentIncludesTrailingAndAdditionalSilence() async {
        let pipeline = makePipeline()
        var iter = pipeline.segments.makeAsyncIterator()

        let sc = speechChunksToMeetMinimum()
        let vc = silenceChunksToTriggerVAD()       // triggers end of first segment
        let extra = 10                              // 10 × 512 = 5120 extra idle samples

        // First segment
        for _ in 0..<sc { await pipeline.processChunk(speechChunk()) }
        for _ in 0..<vc { await pipeline.processChunk(silenceChunk()) }

        // Additional idle silence before second utterance
        for _ in 0..<extra { await pipeline.processChunk(silenceChunk()) }

        // Second segment
        for _ in 0..<sc { await pipeline.processChunk(speechChunk()) }
        await pipeline.forceEnd()

        _ = await iter.next()   // consume first
        let second = await iter.next()!

        // silenceBefore = trailing silence that ended segment 1 + extra idle silence
        let trailingSamples = vc * 512
        let extraSamples    = extra * 512
        let expected = Duration.seconds(Double(trailingSamples + extraSamples) / Self.SR)
        XCTAssertEqual(second.silenceBefore, expected)
        XCTAssertEqual(second.trailingSilenceAfter, .zero)
    }

    // MARK: - Audio content

    func testSegmentAudioContainsSpeechSamples() async {
        let pipeline = makePipeline()
        var iter = pipeline.segments.makeAsyncIterator()

        let n = speechChunksToMeetMinimum()
        for _ in 0..<n { await pipeline.processChunk(speechChunk()) }
        await pipeline.forceEnd()

        let segment = await iter.next()!
        XCTAssertFalse(segment.audio.isEmpty)
        // All speech samples should be 0.1
        XCTAssertEqual(segment.audio.first!, 0.1, accuracy: 1e-6)
    }

    func testSpeechTerminatedBeforeTrailingSilenceThresholdDoesNotMarkEndedBySilence() async {
        let pipeline = makePipeline()
        var iter = pipeline.segments.makeAsyncIterator()

        for _ in 0..<speechChunksToMeetMinimum() { await pipeline.processChunk(speechChunk()) }
        await pipeline.processChunk(silenceChunk(3_200))
        await pipeline.forceEnd()

        let segment = await iter.next()!
        XCTAssertEqual(segment.trailingSilenceAfter, .milliseconds(200))
        XCTAssertEqual(segment.endedBySilence, false)
    }
}
