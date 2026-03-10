import Foundation

protocol AudioPipeline {
    func start() async
    func stop() async
    func forceEnd() async
    var segments: AsyncStream<SpeechSegment> { get }
}

protocol HotkeyManager {
    var events: AsyncStream<HotkeyEvent> { get }
}

protocol Transcriber {
    func transcribe(_ segment: SpeechSegment) async -> TranscriptionResult
}

protocol IntentResolver {
    func resolve(_ result: TranscriptionResult, mode: InputMode) -> Intent
}

protocol OutputManager {
    func append(_ text: String)
    func send()
    func clear()
}
