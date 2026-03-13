## Task 1
- desc: Bootstrap the macOS SwiftUI menu bar app and package structure with only the approved third-party dependencies wired in
- deps: none
- passes: true
- ac:
  - The project builds on macOS 14.0+ as a menu bar app with no Dock icon
  - WhisperKit is the only third-party dependency declared
  - Core protocols and domain types from the spec exist with module boundaries that hide implementation details
- verify: xcodebuild -scheme Egregore -destination 'platform=macOS' build

## Task 2
- desc: Implement the shell integration installer and managed zsh snippet lifecycle for per-session pipe registration
- deps: Task 1
- passes: true
- ac:
  - First-launch flow can present the exact managed zsh integration block before writing to ~/.zshrc
  - Install appends or refreshes the marked block idempotently and creates the session registry/activity directory layout under ~/.config/egregore/
  - The managed snippet records prompt-ready shell metadata and supports `inject`, `clear`, and `send` actions over the same pipe protocol
  - Uninstall removes the managed block from ~/.zshrc and deletes Egregore shell integration state
- verify: swift test --filter ShellIntegrationInstallerTests

## Task 3
- desc: Build OutputManager session discovery and pipe transport so append, clear, and send target the focused zsh session correctly
- deps: Task 1, Task 2
- passes: true
- ac:
  - OutputManager resolves the frontmost application, ranks registered shell sessions by prompt/focus readiness before recency, and writes to the best candidate pipe without exposing process-tree or pipe details to callers
  - append writes inject messages that preserve space-separated buffer concatenation semantics across repeated calls
  - clear resets the buffer and send submits the existing shell buffer without re-injecting text
- verify: swift test --filter OutputManagerTests

## Task 4
- desc: Implement IntentResolver with fixed command vocabulary, confidence floor, and isolation timing rules
- deps: Task 1
- passes: true
- ac:
  - ROGER and ABORT resolve to commands only when the utterance satisfies the isolation algorithm (endedBySilence + short duration)
  - Non-vocabulary text never resolves to a command regardless of timing metadata
  - Low-confidence transcriptions resolve to discard before injection or command execution
- verify: swift test --filter IntentResolverTests

## Task 5
- desc: Add the WhisperKit-backed Transcriber with lazy model download, model storage, warmup, and progress reporting hooks
- deps: Task 1
- passes: true
- ac:
  - The transcriber stores the Core ML Whisper model under ~/.local/share/egregore/models/
  - App startup can begin a shared background model prewarm/download when the model is missing, and concurrent partial/final requests reuse the same in-flight load instead of stampeding model setup
  - Transcription results return text, confidence, and original segment timing metadata without leaking WhisperKit internals
- verify: swift test --filter WhisperKitTranscriberTests

## Task 6
- desc: Implement the audio pipeline using AVAudioEngine, 16kHz mono segment output, and VAD segmentation
- deps: Task 1
- passes: true
- ac:
  - AudioPipeline hides AVFoundation details and emits SpeechSegment values with normalized audio, duration, silenceBefore, trailingSilenceAfter, and endedBySilence metadata
  - VAD self-terminates utterances without caller-managed segmentation knobs
- verify: swift test --filter AudioPipelineTests

## Task 7
- desc: Implement the hotkey manager for toggle key handling and resolved hotkey event streaming
- deps: Task 1
- passes: true
- ac:
  - Tapping Right Control emits a toggle event
  - The toggle key is configurable via HotkeyBindings
- verify: swift test --filter HotkeyManagerTests

## Task 8
- desc: Build SessionController orchestration so transcribed segments map to injection, send, clear, or discard outcomes exactly as specified
- deps: Task 3, Task 4, Task 5, Task 6, Task 7
- passes: true
- ac:
  - Toggle on starts recording, toggle off stops
  - Transcribed utterances append resolved text while discards become no-ops
  - Isolated command words route to send or clear through the same coordinator
  - After processing a segment, recording auto-restarts
- verify: swift test --filter SessionControllerIntegrationTests

## Task 9
- desc: Implement the floating HUD as a pure observer of session state with recording, transcribing, injected, cleared, and idle behaviors
- deps: Task 5, Task 8
- passes: true
- ac:
  - The HUD presents in a non-key, click-through floating window that never steals focus from the active terminal
  - Recording shows live partial text, transcribing shows activity, injected fades out, cleared dismisses immediately, output failures show a short visible error, and idle stays hidden
- verify: xcodebuild test -scheme Egregore -destination 'platform=macOS' -only-testing:EgregoreTests/HUDStateTests

## Task 10
- desc: Add proof-oriented property and end-to-end tests that map directly to the spec milestones and run in CI without microphone hardware
- deps: Task 3, Task 4, Task 5, Task 8
- passes: true
- ac:
  - Property-based tests cover IntentResolver command matching, non-command rejection, low-confidence discard behavior, and OutputManager buffer semantics
  - End-to-end tests exercise transcriber, resolver, output formatting, and full mocked pipeline flows without requiring audio hardware
  - The suite names or groups tests by spec feature so passing results can be traced back to the required behaviors and milestones
- verify: swift test

## Task 11
- desc: Add persistent runtime logging and debug surfaces so hotkeys, audio capture, transcription, intent resolution, and terminal output failures are diagnosable on a real desktop session
- deps: none
- passes: true
- ac:
  - The app writes timestamped logs for the main execution path to a user-owned file under Egregore's local app data
  - Failures that currently no-op silently, especially shell session lookup and pipe writes, emit explicit error logs with enough context to debug the failing step
  - The menu bar UI exposes the active log location or a direct way to inspect recent diagnostics during manual testing
- verify: swift test && manual check that launching the app produces a readable log file

## Task 12
- desc: Make terminal injection and command dispatch observable and reliable against a real zsh session after shell integration install
- deps: Task 11
- passes: true
- ac:
  - Final transcriptions either append to the active terminal buffer or emit logs showing exactly where resolution failed
  - Session discovery logs include the frontmost app PID, shell PID traversal, matched registry PID ancestry, and prompt/focus metadata used for candidate ranking without exposing implementation details to callers
  - ROGER and ABORT attempts log whether the app executed send or clear and whether shell targeting was applied, refused as ambiguous, or failed in delivery
  - The managed zsh snippet supports an opt-in debug log that proves handler entry and post-mutation buffer state during manual debugging
- verify: swift test --filter ShellIntegrationInstallerTests && manual check in a fresh zsh terminal after installing the managed snippet, with logs confirming append and clear paths

## Task 13
- desc: Replace brittle fixed hotkey assumptions with a user-appropriate input scheme and visible configuration state for treadmill use
- deps: Task 11
- passes: true
- ac:
  - The default toggle binding works on common external keyboards
  - The menu bar UI shows the current binding in user-facing language instead of hardcoded stale text
  - Manual testing can confirm which physical key events the app is receiving when a binding does not behave as expected
- verify: swift test --filter HotkeyManagerTests && manual check that the configured toggle binding registers on the target keyboard

## Task 14
- desc: Implement real-time speech-to-text feedback so the HUD shows a live transcript during capture and injects the finalized text when the utterance ends
- deps: Task 11, Task 12
- passes: true
- ac:
  - While an utterance is actively being captured, the HUD moves from `Listening` into incrementally updated transcript text with low enough latency to provide immediate user feedback
  - A completed utterance detected by silence keeps the most recent transcript visible while finalizing, then injects the finalized text into the focused terminal session
- verify: swift test --filter HUDStateTests && manual check of one utterance from live HUD transcript through final terminal injection

## Task 15
- desc: Replace snapshot-final HUD updates with true incremental partial transcription that stays visible long enough to be perceptible during live capture
- deps: Task 5, Task 8, Task 9, Task 14
- passes: true
- ac:
  - During an active utterance, the HUD updates from WhisperKit callback partials rather than waiting for a completed snapshot decode result
  - Partial transcript updates are frequent and stable enough to be visually perceived before final injection occurs
  - Final transcript completion keeps the latest visible text stable and transitions cleanly into transcribing/injected behavior without stale partial flashes or immediate HUD bounce
- verify: swift test --filter HUDStateTests && manual check that a multi-word utterance visibly updates in place while speaking

## Task 16
- desc: Make spoken ROGER and ABORT resolve to commands reliably in real use instead of falling through to normal text injection
- deps: Task 4, Task 6, Task 8, Task 12
- passes: true
- ac:
  - Naturally spoken standalone `ROGER` and `ABORT` trigger send and clear outcomes reliably enough for treadmill use without requiring brittle silence timing that commonly misclassifies them as dictation
  - Normal dictation containing command words in longer phrases still injects as text unless the utterance satisfies the intended command criteria
  - Final dictation headed to terminal injection strips trailing spoken punctuation so commands do not arrive as `git status.` when the user intended `git status`
- verify: swift test --filter IntentResolverTests && swift test --filter SessionControllerIntegrationTests && manual check that standalone spoken `ROGER` and `ABORT` do not append to the terminal

## Task 17
- desc: Add higher-confidence integration proof for live partial HUD behavior and real command execution so mocked tests cannot mask regressions
- deps: Task 12, Task 15, Task 16
- passes: true
- ac:
  - Automated tests prove that partial transcription callbacks can reach the HUD as multiple visible updates during a single utterance
  - Automated or harnessed integration proof verifies that `ROGER` and `ABORT` execute send and clear behavior through the real output path instead of merely resolving to mocked command intents
  - The proof surfaces timing-sensitive regressions that the current mocked snapshot and resolver tests do not catch
- verify: swift test && manual check of one live partial-transcript utterance plus one live `ROGER` and one live `ABORT` command against a fresh zsh session
