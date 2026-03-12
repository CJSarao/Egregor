import AppKit
import Foundation

struct KeyBinding: Sendable, Equatable {
    let keyCode: UInt16
    let flag: NSEvent.ModifierFlags
    let displayName: String

    static func == (lhs: KeyBinding, rhs: KeyBinding) -> Bool {
        lhs.keyCode == rhs.keyCode && lhs.flag == rhs.flag && lhs.displayName == rhs.displayName
    }
}

struct HotkeyBindings: Sendable {
    let pttKey: KeyBinding
    let commandModifier: KeyBinding
    let modeToggle: KeyBinding

    static let `default` = HotkeyBindings(
        pttKey: KeyBinding(keyCode: 54, flag: .command, displayName: "Right Command"),
        commandModifier: KeyBinding(keyCode: 60, flag: .shift, displayName: "Right Shift"),
        modeToggle: KeyBinding(keyCode: 62, flag: .control, displayName: "Right Control")
    )
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
    case pttBegan
    case pttEnded(mode: InputMode)
    case modeToggled
}

enum InputMode: Equatable {
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

enum HUDState: Equatable {
    case idle
    case recording(mode: SessionController.OperatingMode, partialText: String? = nil)
    case transcribing
    case injected(String)
    case cleared
}
