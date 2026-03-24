import AppKit
import Foundation

struct KeyBinding: Equatable {
    let keyCode: UInt16
    let flag: NSEvent.ModifierFlags
    let displayName: String
}

struct HotkeyBindings {
    static let `default` = Self(
        toggleKey: KeyBinding(keyCode: 62, flag: .control, displayName: "Right Control")
    )

    let toggleKey: KeyBinding
}

struct SpeechSegment {
    let audio: [Float]
    let silenceBefore: Duration
    let duration: Duration
    let trailingSilenceAfter: Duration
    let endedBySilence: Bool
}

struct SpeechCaptureSnapshot: Equatable {
    let audio: [Float]
    let duration: Duration
}

struct TranscriptionResult {
    let text: String
    let confidence: Float
    let segment: SpeechSegment
}

enum HotkeyEvent: Equatable {
    case toggle
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

enum OutputResult: Equatable {
    case success
    case failure(String)
}

enum HUDState: Equatable {
    case idle
    case loading
    case listening
    case recording
    case streaming
    case transcribing
    case injected(continueListening: Bool = false)
    case cleared(continueListening: Bool = false)
    case error(String, continueListening: Bool = false)
}
