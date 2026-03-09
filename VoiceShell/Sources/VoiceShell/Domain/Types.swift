import Foundation

struct SpeechSegment {
    let audio: [Float]
    let silenceBefore: Duration
    let duration: Duration
}

struct TranscriptionResult {
    let text: String
    let confidence: Float
    let segment: SpeechSegment
}

enum HotkeyEvent {
    case pttBegan
    case pttEnded(mode: InputMode)
    case modeToggled
}

enum InputMode {
    case dictation
    case command
}

enum Intent {
    case inject(String)
    case command(VoiceCommand)
    case discard
}

enum VoiceCommand {
    case roger
    case abort
}
