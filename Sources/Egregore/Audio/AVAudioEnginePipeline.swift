import AVFoundation
import Foundation

actor AVAudioEnginePipeline: AudioPipeline {

    // VAD constants — sample-count-based for deterministic behaviour at 16 kHz.
    // 512 samples ≈ 32 ms per chunk; 800 ms ≈ 25 chunks; 100 ms ≈ 3 chunks.
    static let outputSampleRate: Double = 16_000
    static let silenceRMSThreshold: Float = 0.01
    static let silenceSamplesThreshold = 12_800   // 800 ms at 16 kHz
    static let minimumSpeechSamples    = 1_600    // 100 ms at 16 kHz
    static let partialSnapshotSamplesThreshold = 3_200 // 200 ms at 16 kHz

    // Wraps the start/stop lifecycle of a live or injected audio source.
    struct TapHandle: Sendable {
        let start: @Sendable () -> Void
        let stop:  @Sendable () -> Void
    }

    // Receives a Sendable chunk callback, returns a TapHandle.
    typealias TapInstaller = @Sendable (@Sendable @escaping ([Float]) -> Void) -> TapHandle

    private let tapInstaller: TapInstaller
    private var tapHandle: TapHandle?
    private var processingTask: Task<Void, Never>?
    private var chunkContinuation: AsyncStream<[Float]>.Continuation?

    // Output stream — created once, lives for the actor's lifetime.
    private let segmentContinuation: AsyncStream<SpeechSegment>.Continuation
    nonisolated let segments: AsyncStream<SpeechSegment>
    private let snapshotContinuation: AsyncStream<SpeechCaptureSnapshot>.Continuation
    nonisolated let captureSnapshots: AsyncStream<SpeechCaptureSnapshot>

    // VAD state — sample-count-based, mutated only on the actor.
    private var speechBuffer: [Float] = []
    private var speechSampleCount    = 0
    private var silenceBeforeSpeech  = 0   // idle samples accumulated before current utterance
    private var trailingSilenceCount = 0   // consecutive silence samples after speech started
    private var samplesSinceLastEnd  = 0   // idle samples since last segment ended
    private var inSpeech             = false
    private var samplesSinceLastSnapshot = 0

    init(tapInstaller: @escaping TapInstaller = AVAudioEnginePipeline.makeLiveTapInstaller()) {
        var segmentCont: AsyncStream<SpeechSegment>.Continuation!
        segments = AsyncStream { segmentCont = $0 }
        segmentContinuation = segmentCont

        var snapshotCont: AsyncStream<SpeechCaptureSnapshot>.Continuation!
        captureSnapshots = AsyncStream { snapshotCont = $0 }
        snapshotContinuation = snapshotCont
        self.tapInstaller = tapInstaller
    }

    // MARK: - AudioPipeline

    func start() {
        var chunkCont: AsyncStream<[Float]>.Continuation!
        let audioChunks = AsyncStream<[Float]> { chunkCont = $0 }
        let cont = chunkCont!
        chunkContinuation = cont

        let handle = tapInstaller { chunk in cont.yield(chunk) }
        tapHandle = handle
        handle.start()

        processingTask = Task { [weak self] in
            for await chunk in audioChunks {
                await self?.processChunk(chunk)
            }
        }
    }

    func stop() {
        tapHandle?.stop()
        tapHandle = nil
        emitCurrentSegment(endedBySilence: false)        // emit in-progress speech before tearing down
        chunkContinuation?.finish()
        chunkContinuation = nil
        processingTask = nil
        resetVADState()
        samplesSinceLastEnd = 0
    }

    func forceEnd() {
        guard inSpeech else { return }
        emitCurrentSegment(endedBySilence: false)
        resetVADState()
    }

    // MARK: - VAD processing (internal for direct test access)

    func processChunk(_ chunk: [Float]) {
        let rms = Self.computeRMS(chunk)
        let n   = chunk.count

        if rms > Self.silenceRMSThreshold {
            if !inSpeech {
                inSpeech = true
                silenceBeforeSpeech = samplesSinceLastEnd
                trailingSilenceCount = 0
                samplesSinceLastSnapshot = 0
            }
            speechBuffer.append(contentsOf: chunk)
            speechSampleCount += n
            trailingSilenceCount = 0
            samplesSinceLastSnapshot += n
        } else if inSpeech {
            speechBuffer.append(contentsOf: chunk)
            trailingSilenceCount += n
            samplesSinceLastSnapshot += n
            if trailingSilenceCount >= Self.silenceSamplesThreshold {
                emitCurrentSegment(endedBySilence: true)
                resetVADState()
            }
        } else {
            samplesSinceLastEnd += n
        }

        emitSnapshotIfNeeded()
    }

    // MARK: - Private helpers

    private func emitCurrentSegment(endedBySilence: Bool) {
        guard inSpeech, speechSampleCount >= Self.minimumSpeechSamples else { return }
        let duration     = Duration.seconds(Double(speechSampleCount)   / Self.outputSampleRate)
        let silenceBefore = Duration.seconds(Double(silenceBeforeSpeech) / Self.outputSampleRate)
        let trailingSilenceAfter = Duration.seconds(Double(trailingSilenceCount) / Self.outputSampleRate)
        segmentContinuation.yield(SpeechSegment(
            audio: speechBuffer,
            silenceBefore: silenceBefore,
            duration: duration,
            trailingSilenceAfter: trailingSilenceAfter,
            endedBySilence: endedBySilence
        ))
        samplesSinceLastEnd = trailingSilenceCount
    }

    private func emitSnapshotIfNeeded() {
        guard inSpeech,
              speechSampleCount >= Self.minimumSpeechSamples,
              samplesSinceLastSnapshot >= Self.partialSnapshotSamplesThreshold else { return }
        let duration = Duration.seconds(Double(speechBuffer.count) / Self.outputSampleRate)
        snapshotContinuation.yield(SpeechCaptureSnapshot(audio: speechBuffer, duration: duration))
        samplesSinceLastSnapshot = 0
    }

    private func resetVADState() {
        speechBuffer        = []
        speechSampleCount   = 0
        silenceBeforeSpeech = 0
        trailingSilenceCount = 0
        inSpeech            = false
        samplesSinceLastSnapshot = 0
    }

    static func computeRMS(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        return (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }

    // MARK: - Live tap (AVAudioEngine)

    nonisolated static func makeLiveTapInstaller() -> TapInstaller {
        { callback in
            let engine = AVAudioEngine()
            let input  = engine.inputNode
            let sourceFormat = input.inputFormat(forBus: 0)
            let targetFormat = AVAudioFormat(standardFormatWithSampleRate: outputSampleRate, channels: 1)!
            let converter = AVAudioConverter(from: sourceFormat, to: targetFormat)

            // Input-node taps must match the hardware format. Resample to the app's
            // fixed 16 kHz mono Float32 contract after capture.
            input.installTap(onBus: 0, bufferSize: 1024, format: sourceFormat) { buffer, _ in
                guard let converted = convert(buffer,
                                              from: sourceFormat,
                                              to: targetFormat,
                                              using: converter),
                      let data = converted.floatChannelData else { return }
                let samples = Array(UnsafeBufferPointer(start: data[0], count: Int(converted.frameLength)))
                callback(samples)
            }
            return TapHandle(
                start: { try? engine.start() },
                stop:  { engine.stop(); input.removeTap(onBus: 0) }
            )
        }
    }

    private nonisolated static func convert(
        _ buffer: AVAudioPCMBuffer,
        from sourceFormat: AVAudioFormat,
        to targetFormat: AVAudioFormat,
        using converter: AVAudioConverter?
    ) -> AVAudioPCMBuffer? {
        guard let converter else { return nil }

        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let outputCapacity = max(1, Int(ceil(Double(buffer.frameLength) * ratio)))
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat,
                                                  frameCapacity: AVAudioFrameCount(outputCapacity)) else {
            return nil
        }

        var error: NSError?
        var consumed = false
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .endOfStream
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard status == .haveData || status == .endOfStream, error == nil else { return nil }
        return outputBuffer.frameLength > 0 ? outputBuffer : nil
    }
}
