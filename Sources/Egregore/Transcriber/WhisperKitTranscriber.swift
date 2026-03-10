import Foundation
import WhisperKit

actor WhisperKitTranscriber: Transcriber {
    static let modelVariant = "openai_whisper-large-v3-turbo"
    static let modelStorageURL = URL.homeDirectory
        .appending(path: ".local/share/egregore/models", directoryHint: .isDirectory)

    // Injected engine: receives raw audio, returns (text, avgLogprobs) without leaking WhisperKit types.
    // Production path creates WhisperKit lazily; test path injects a stub.
    private let engineProvider: @Sendable () async throws -> @Sendable ([Float]) async throws -> (text: String, avgLogprobs: [Float])
    private var engine: (@Sendable ([Float]) async throws -> (text: String, avgLogprobs: [Float]))?
    private let progressHandler: ((Double) -> Void)?

    init(progressHandler: ((Double) -> Void)? = nil) {
        self.progressHandler = progressHandler
        let ph = progressHandler
        self.engineProvider = {
            try await WhisperKitTranscriber.makeEngine(progressHandler: ph)
        }
    }

    // Testability — inject a stub engine factory
    init(
        engineProvider: @escaping @Sendable () async throws -> @Sendable ([Float]) async throws -> (text: String, avgLogprobs: [Float]),
        progressHandler: ((Double) -> Void)? = nil
    ) {
        self.engineProvider = engineProvider
        self.progressHandler = progressHandler
    }

    func transcribe(_ segment: SpeechSegment) async -> TranscriptionResult {
        do {
            let run = try await loadedEngine()
            let (text, avgLogprobs) = try await run(segment.audio)
            let confidence = Self.confidence(from: avgLogprobs)
            return TranscriptionResult(text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                                       confidence: confidence,
                                       segment: segment)
        } catch {
            return TranscriptionResult(text: "", confidence: 0, segment: segment)
        }
    }

    private func loadedEngine() async throws -> @Sendable ([Float]) async throws -> (text: String, avgLogprobs: [Float]) {
        if let engine { return engine }
        let e = try await engineProvider()
        engine = e
        return e
    }

    // exp(mean_avgLogprob) maps log-prob domain to [0,1]: log(1)=0→confidence 1.0, lower log-probs→lower confidence
    static func confidence(from avgLogprobs: [Float]) -> Float {
        guard !avgLogprobs.isEmpty else { return 0 }
        let mean = avgLogprobs.reduce(0, +) / Float(avgLogprobs.count)
        return max(0, min(1, Foundation.exp(mean)))
    }

    private static func makeEngine(progressHandler: ((Double) -> Void)?) async throws -> @Sendable ([Float]) async throws -> (text: String, avgLogprobs: [Float]) {
        let kit = try await WhisperKit(
            model: modelVariant,
            downloadBase: modelStorageURL,
            verbose: false,
            prewarm: false,
            load: true,
            download: true
        )
        if let handler = progressHandler {
            kit.modelStateCallback = { _, newState in
                if newState == .loaded { handler(1.0) }
            }
        }
        return { audioArray in
            let results = try await kit.transcribe(audioArray: audioArray)
            let text = results.map(\.text).joined(separator: " ")
            let avgLogprobs = results.flatMap(\.segments).map(\.avgLogprob)
            return (text, avgLogprobs)
        }
    }
}
