import Foundation
import WhisperKit

actor WhisperKitTranscriber: Transcriber {
    static let modelVariant = "openai_whisper-large-v3_turbo"
    static let modelStorageURL = URL.homeDirectory
        .appending(path: ".local/share/egregore/models", directoryHint: .isDirectory)

    typealias Engine = @Sendable ([Float], @escaping @Sendable (String) -> Void) async throws -> (text: String, avgLogprobs: [Float])

    private let engineProvider: @Sendable () async throws -> Engine
    private var engine: Engine?
    private var engineLoadTask: Task<Engine, Error>?
    private let progressHandler: ((Double) -> Void)?
    private let log: RuntimeLogger

    nonisolated let partialTextStream: AsyncStream<String>
    private let partialContinuation: AsyncStream<String>.Continuation

    init(progressHandler: ((Double) -> Void)? = nil, logger: RuntimeLogger = .shared) {
        self.progressHandler = progressHandler
        self.log = logger
        let ph = progressHandler
        self.engineProvider = { () async throws -> Engine in
            try await WhisperKitTranscriber.makeEngine(progressHandler: ph)
        }
        var cont: AsyncStream<String>.Continuation!
        partialTextStream = AsyncStream { cont = $0 }
        partialContinuation = cont!
    }

    init(
        engineProvider: @escaping @Sendable () async throws -> Engine,
        progressHandler: ((Double) -> Void)? = nil,
        logger: RuntimeLogger = .shared
    ) {
        self.engineProvider = engineProvider
        self.progressHandler = progressHandler
        self.log = logger
        var cont: AsyncStream<String>.Continuation!
        partialTextStream = AsyncStream { cont = $0 }
        partialContinuation = cont!
    }

    func transcribePartial(_ snapshot: SpeechCaptureSnapshot) async -> String {
        guard !snapshot.audio.isEmpty else { return "" }
        do {
            let run = try await loadedEngine()
            let cont = partialContinuation
            let (text, _) = try await run(snapshot.audio) { partial in cont.yield(partial) }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                log.log("partial transcription: duration=\(snapshot.duration) chars=\(trimmed.count)", category: .transcriber)
            }
            return trimmed
        } catch is CancellationError {
            return ""
        } catch {
            log.error("partial transcription failed: \(error)", category: .transcriber)
            return ""
        }
    }

    func transcribe(_ segment: SpeechSegment) async -> TranscriptionResult {
        do {
            let run = try await loadedEngine()
            let cont = partialContinuation
            let (text, avgLogprobs) = try await run(segment.audio) { partial in cont.yield(partial) }
            let confidence = Self.confidence(from: avgLogprobs)
            log.log("transcribed \(segment.audio.count) samples → \(text.count) chars (confidence \(confidence))", category: .transcriber)
            return TranscriptionResult(text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                                       confidence: confidence,
                                       segment: segment)
        } catch {
            log.error("transcription failed: \(error)", category: .transcriber)
            return TranscriptionResult(text: "", confidence: 0, segment: segment)
        }
    }

    func prepare() async {
        do {
            _ = try await loadedEngine()
        } catch {
            log.error("engine prewarm failed: \(error)", category: .transcriber)
        }
    }

    private func loadedEngine() async throws -> Engine {
        if let engine { return engine }
        if let engineLoadTask {
            return try await engineLoadTask.value
        }

        log.log("loading WhisperKit engine (model: \(Self.modelVariant), storage: \(Self.modelStorageURL.path()))", category: .transcriber)
        let task = Task { try await engineProvider() }
        engineLoadTask = task

        do {
            let e = try await task.value
            engine = e
            engineLoadTask = nil
            log.log("WhisperKit engine loaded", category: .transcriber)
            return e
        } catch {
            engineLoadTask = nil
            throw error
        }
    }

    // exp(mean_avgLogprob) maps log-prob domain to [0,1]: log(1)=0→confidence 1.0, lower log-probs→lower confidence
    static func confidence(from avgLogprobs: [Float]) -> Float {
        guard !avgLogprobs.isEmpty else { return 0 }
        let mean = avgLogprobs.reduce(0, +) / Float(avgLogprobs.count)
        return max(0, min(1, Foundation.exp(mean)))
    }

    private static func makeEngine(progressHandler: ((Double) -> Void)?) async throws -> Engine {
        let config = WhisperKitConfig(
            model: modelVariant,
            downloadBase: modelStorageURL,
            modelRepo: "argmaxinc/whisperkit-coreml",
            verbose: false,
            prewarm: false,
            load: true,
            download: true
        )
        let kit = try await WhisperKit(config)
        if let handler = progressHandler {
            kit.modelStateCallback = { _, newState in
                if newState == .loaded { handler(1.0) }
            }
        }
        return { (audioArray: [Float], onPartial: @escaping @Sendable (String) -> Void) async throws -> (text: String, avgLogprobs: [Float]) in
            let results = try await kit.transcribe(
                audioArray: audioArray,
                callback: { progress in
                    let partial = progress.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !partial.isEmpty { onPartial(partial) }
                    return nil
                }
            )
            let text = results.map(\.text).joined(separator: " ")
            let avgLogprobs = results.flatMap(\.segments).map(\.avgLogprob)
            return (text, avgLogprobs)
        }
    }
}
