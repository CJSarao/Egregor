import Foundation

protocol AudioPipeline {
    func start() async
    func stop() async
    func forceEnd() async
    var segments: AsyncStream<SpeechSegment> { get }
    var captureSnapshots: AsyncStream<SpeechCaptureSnapshot> { get }
}

protocol HotkeyManager {
    var events: AsyncStream<HotkeyEvent> { get }
}

protocol Transcriber {
    var partialTextStream: AsyncStream<String> { get }
    func transcribePartial(_ snapshot: SpeechCaptureSnapshot) async -> String
    func transcribe(_ segment: SpeechSegment) async -> TranscriptionResult
}

protocol IntentResolver {
    func resolve(_ result: TranscriptionResult, mode: InputMode) -> Intent
}

protocol OutputManager {
    func append(_ text: String) -> OutputResult
    func send() -> OutputResult
    func clear() -> OutputResult
}
