import AVFoundation
import Foundation

actor AVAudioEnginePipeline: AudioPipeline {

    // VAD constants — sample-count-based for deterministic behaviour at 16 kHz.
    // 512 samples ≈ 32 ms per chunk; 700 ms ≈ 22 chunks; 100 ms ≈ 3 chunks.
    static let outputSampleRate: Double = 16_000
    static let silenceRMSThreshold: Float = 0.01
    static let silenceSamplesThreshold = 11_200   // 700 ms at 16 kHz
    static let minimumSpeechSamples    = 1_600    // 100 ms at 16 kHz

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

    // VAD state — sample-count-based, mutated only on the actor.
    private var speechBuffer: [Float] = []
    private var speechSampleCount    = 0
    private var silenceBeforeSpeech  = 0   // idle samples accumulated before current utterance
    private var trailingSilenceCount = 0   // consecutive silence samples after speech started
    private var samplesSinceLastEnd  = 0   // idle samples since last segment ended
    private var inSpeech             = false

    init(tapInstaller: @escaping TapInstaller = AVAudioEnginePipeline.makeLiveTapInstaller()) {
        var cont: AsyncStream<SpeechSegment>.Continuation!
        segments = AsyncStream { cont = $0 }
        segmentContinuation = cont
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
        emitCurrentSegment()        // emit in-progress speech before tearing down
        chunkContinuation?.finish()
        chunkContinuation = nil
        processingTask = nil
        resetVADState()
        samplesSinceLastEnd = 0
    }

    func forceEnd() {
        guard inSpeech else { return }
        emitCurrentSegment()
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
            }
            speechBuffer.append(contentsOf: chunk)
            speechSampleCount += n
            trailingSilenceCount = 0
        } else if inSpeech {
            speechBuffer.append(contentsOf: chunk)
            trailingSilenceCount += n
            if trailingSilenceCount >= Self.silenceSamplesThreshold {
                emitCurrentSegment()
                resetVADState()
            }
        } else {
            samplesSinceLastEnd += n
        }
    }

    // MARK: - Private helpers

    private func emitCurrentSegment() {
        guard inSpeech, speechSampleCount >= Self.minimumSpeechSamples else { return }
        let duration     = Duration.seconds(Double(speechSampleCount)   / Self.outputSampleRate)
        let silenceBefore = Duration.seconds(Double(silenceBeforeSpeech) / Self.outputSampleRate)
        segmentContinuation.yield(SpeechSegment(
            audio: speechBuffer,
            silenceBefore: silenceBefore,
            duration: duration
        ))
        samplesSinceLastEnd = trailingSilenceCount
    }

    private func resetVADState() {
        speechBuffer        = []
        speechSampleCount   = 0
        silenceBeforeSpeech = 0
        trailingSilenceCount = 0
        inSpeech            = false
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
            let format = AVAudioFormat(standardFormatWithSampleRate: outputSampleRate, channels: 1)!
            input.installTap(onBus: 0, bufferSize: 512, format: format) { buffer, _ in
                guard let data = buffer.floatChannelData else { return }
                let samples = Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
                callback(samples)
            }
            return TapHandle(
                start: { try? engine.start() },
                stop:  { engine.stop(); input.removeTap(onBus: 0) }
            )
        }
    }
}
