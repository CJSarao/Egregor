## Task 1
- desc: Bootstrap the macOS SwiftUI menu bar app and package structure with only the approved third-party dependencies wired in
- deps: none
- passes: true
- ac:
  - The project builds on macOS 14.0+ as a menu bar app with no Dock icon
  - WhisperKit and KeyboardShortcuts are the only third-party dependencies declared
  - Core protocols and domain types from the spec exist with module boundaries that hide implementation details
- verify: xcodebuild -scheme VoiceShell -destination 'platform=macOS' build

## Task 2
- desc: Implement the shell integration installer and managed zsh snippet lifecycle for per-session pipe registration
- deps: Task 1
- passes: true
- ac:
  - First-launch flow can present the exact managed zsh integration block before writing to ~/.zshrc
  - Install appends the marked block idempotently and creates the session registry directory layout under ~/.config/voiceshell/
  - Uninstall removes the managed block from ~/.zshrc and deletes VoiceShell shell integration state
- verify: swift test --filter ShellIntegrationInstallerTests

## Task 3
- desc: Build OutputManager session discovery and pipe transport so append, clear, and send target the focused zsh session correctly
- deps: Task 1, Task 2
- passes: true
- ac:
  - OutputManager resolves the frontmost application, finds a registered shell session, and writes to its pipe without exposing process-tree or pipe details to callers
  - append writes inject messages that preserve space-separated buffer concatenation semantics across repeated calls
  - clear resets the buffer and send emits a Return keystroke path without re-injecting text
- verify: swift test --filter OutputManagerTests

## Task 4
- desc: Implement IntentResolver with fixed command vocabulary, confidence floor, and OPEN-mode isolation timing rules
- deps: Task 1
- passes: true
- ac:
  - ROGER and ABORT resolve to commands only when the utterance satisfies the isolation algorithm and current input mode permits command handling
  - Non-vocabulary text never resolves to a command regardless of timing metadata
  - Low-confidence transcriptions resolve to discard before injection or command execution
- verify: swift test --filter IntentResolverTests

## Task 5
- desc: Add the WhisperKit-backed Transcriber with lazy model download, model storage, warmup, and progress reporting hooks
- deps: Task 1
- passes: true
- ac:
  - The transcriber stores the Core ML Whisper model under ~/.local/share/voiceshell/models/
  - First transcription triggers lazy download and compile when the model is missing, while later transcriptions reuse the cached model
  - Transcription results return text, confidence, and original segment timing metadata without leaking WhisperKit internals
- verify: swift test --filter WhisperKitTranscriberTests

## Task 6
- desc: Implement the audio pipeline using AVAudioEngine, 16kHz mono segment output, VAD segmentation, and forceEnd handling
- deps: Task 1
- passes: true
- ac:
  - AudioPipeline hides AVFoundation details and emits SpeechSegment values with normalized audio, duration, and silenceBefore metadata
  - In PTT mode, forceEnd terminates the active segment immediately on key release even if VAD would continue
  - In OPEN mode, VAD self-terminates utterances without caller-managed segmentation knobs
- verify: swift test --filter AudioPipelineTests

## Task 7
- desc: Implement the hotkey manager for right-side modifier handling, persistent mode toggling, and resolved hotkey event streaming
- deps: Task 1
- passes: true
- ac:
  - Holding Right Option emits PTT begin and end events for dictation mode
  - Holding Right Shift with Right Option emits command-mode PTT events
  - Tapping Right Control toggles between PTT and OPEN modes and the selected mode persists for the app session
- verify: swift test --filter HotkeyManagerTests

## Task 8
- desc: Build SessionController orchestration so transcribed segments map to injection, send, clear, or discard outcomes exactly as specified
- deps: Task 3, Task 4, Task 5, Task 6, Task 7
- passes: false
- ac:
  - PTT dictation events transcribe and append resolved text while discards become no-ops
  - PTT command events can only execute ROGER or ABORT outcomes and never inject text
  - OPEN mode routes isolated commands to send or clear and routes normal utterances to append through the same coordinator
- verify: swift test --filter SessionControllerIntegrationTests

## Task 9
- desc: Implement the floating HUD as a pure observer of session state with recording, transcribing, injected, cleared, and idle behaviors
- deps: Task 5, Task 8
- passes: false
- ac:
  - The HUD presents in a non-key, click-through floating window that never steals focus from the active terminal
  - Recording shows live partial text, transcribing shows activity, injected fades out, cleared dismisses immediately, and idle stays hidden
  - HUD mode indication reflects the current PTT or OPEN state while remaining driven only by published controller state
- verify: xcodebuild test -scheme VoiceShell -destination 'platform=macOS' -only-testing:VoiceShellTests/HUDStateTests

## Task 10
- desc: Add proof-oriented property and end-to-end tests that map directly to the spec milestones and run in CI without microphone hardware
- deps: Task 3, Task 4, Task 5, Task 8
- passes: false
- ac:
  - Property-based tests cover IntentResolver command matching, non-command rejection, low-confidence discard behavior, and OutputManager buffer semantics
  - End-to-end tests exercise transcriber, resolver, output formatting, and full mocked pipeline flows without requiring audio hardware
  - The suite names or groups tests by spec feature so passing results can be traced back to the required behaviors and milestones
- verify: swift test
