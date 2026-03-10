# Egregore — Project Specification

*2026-03-09*
#voice-control #terminal #swift #architecture #spec

---

## 0. Documentation Contract

`specs.md` is the source of truth for product behavior and intended UX.
`tasks.md` is a derived execution plan and must not permanently carry behavior that is absent from the spec.

When implementation, tests, README text, or UI copy materially diverge from this document, they must be reconciled in the same change whenever possible.
Tests are proof that the implementation satisfies the spec, not proof of accidental current behavior.

## 1. What It Is

A macOS menu bar application that transcribes voice input and injects text into the active terminal's shell buffer. Productivity tool for hands-free terminal interaction — not a voice assistant, not an agent, not a dictation replacement for prose.

Primary use case: walking on a treadmill, interacting with Claude Code or any shell-based tool without touching the keyboard.

---

## 2. Software Design Principles

Complexity is the enemy. Every design decision must reduce one of:
- **Change amplification** — one change requires edits in many places
- **Cognitive load** — too much context needed to make a change
- **Unknown unknowns** — unclear what code or knowledge a change requires

### Deep Modules
Modules must have simple interfaces hiding significant complexity. A 40-line method with a clean interface beats five 8-line helpers that scatter one abstraction. Split only when it produces a deeper interface with better information hiding.

### Information Hiding
Each module encapsulates design decisions. Callers must not know internals. If two modules share knowledge of the same design decision, merge them or extract the shared knowledge.

### General-Purpose Interfaces, Specific Implementations
Interfaces must serve multiple callers without modification. Push specialized logic up (to callers/UI) or down (into drivers/adapters), never into core abstractions.

### Different Layer = Different Abstraction
Adjacent layers with similar abstractions should be merged or one must add meaningful transformation.

### Pull Complexity Downward
When complexity is unavoidable, push it into the implementation, not the interface.

### Design It Twice
For any significant abstraction, consider at least two approaches before committing. Compare interfaces, not implementations.

---

## 3. Non-Goals (Explicit)

- Ghostty SDK or any terminal-emulator-specific API
- Clipboard injection (deferred — shell integration first)
- Python prototype or intermediate language step
- Direct pipe architecture (voice → agent without buffer)
- Runtime configuration of VAD/isolation parameters by user
- Cross-platform support (macOS only, personal tool)
- SSH session support
- Prose dictation / document editing use case

---

## 4. Technology Stack

| Component | Technology | Notes |
|---|---|---|
| Language | Swift | No intermediate prototype |
| Minimum macOS | 14.0 (Sonoma) | Personal tool, newest hardware |
| UI | SwiftUI `MenuBarExtra` | No Dock icon |
| Audio capture | `AVFoundation` (`AVAudioEngine`) | Graph-based, installable tap |
| Transcription | WhisperKit (`argmaxinc/whisperkit-coreml`) | Core ML, Apple Neural Engine |
| Model | `openai_whisper-large-v3_turbo` | Best latency/accuracy tradeoff |
| Model storage | `~/.local/share/egregore/models/` | User-owned, inspectable |
| Hotkeys | `KeyboardShortcuts` (sindresorhus) | Wraps NSEvent global monitors |
| Shell integration | ZLE fd watcher (zsh) | Terminal-agnostic, shell-level |
| Session registry | `~/.config/egregore/sessions/` | Per-session pipe registration |
| Session activity | `~/.config/egregore/activity/` | Per-session last-active markers for focused-shell selection |

### Dependencies Policy
Only WhisperKit and KeyboardShortcuts are permitted as third-party dependencies. Any addition requires explicit justification against implementing the functionality directly.

---

## 5. Mode System

Two operational modes, toggled by a persistent hotkey.

### PTT (Push-to-Talk) — default
- Hold PTT key → mic records and HUD shows a live transcript for the current utterance
- Release PTT key → finalize the utterance, hide the live transcript state, and inject the finalized text into the active terminal buffer
- Hold Command mode modifier + PTT key → record single utterance with the same live HUD transcript, then on release parse as command only (no append)

### OPEN (Open Mic)
- VAD runs continuously while OPEN mode is active
- During an utterance, the HUD shows a live transcript for immediate user feedback
- When silence ends the utterance, finalize the transcript, hide the live transcript state, and inject the finalized text into the active terminal buffer
- Isolated command words trigger command parsing (see isolation algorithm below)
- Normal utterances append to terminal buffer — ABORT is the only way to clear

### Mode Toggle
Dedicated hotkey switches between PTT and OPEN. State persists for the session. HUD displays current mode.

### Default Hotkeys

| Action | Key | Mechanism |
|---|---|---|
| PTT record | `Right Command (⌘)` hold | `NSEvent flagsChanged` |
| PTT command mode | `Right Shift + Right Command` hold | `NSEvent flagsChanged` |
| Mode toggle (PTT ↔ OPEN) | `Right Control (^)` tap | `KeyboardShortcuts` |

All defaults use right-side modifier keys only. No conflicts with terminal control sequences, common IDE shortcuts, or macOS system shortcuts. Comfortable to reach without looking — suitable for treadmill use.

---

## 6. Command Vocabulary

Minimal, opinionated. Military-style to prevent false positives in normal speech.

| Command | Word | Action |
|---|---|---|
| Send | `ROGER` | Send Return keystroke to focused terminal. Does NOT re-inject text — text already present from prior injection. |
| Clear | `ABORT` | Clear ZLE BUFFER in focused terminal + clear HUD. |

Vocabulary is fixed. No user configuration.

---

## 7. Isolation Algorithm (OPEN mode command detection)

```
utterance arrives
  silenceBefore > 1500ms  AND
  duration < 2000ms        AND
  [hold 800ms for trailing silence]  AND
  no further speech detected         AND
  text matches command vocabulary
  → Intent.command(_)

else
  → Intent.inject(text)
```

All thresholds are compile-time constants inside `IntentResolver`. Not exposed to callers or users. May be tuned during initial UX development then fixed.

---

## 8. Module Contracts

### AudioPipeline

```swift
protocol AudioPipeline {
    func start() async
    func stop() async
    func forceEnd() async  // PTT release — terminates segment regardless of VAD state
    var segments: AsyncStream<SpeechSegment> { get }
    var captureSnapshots: AsyncStream<SpeechCaptureSnapshot> { get }
}

struct SpeechSegment {
    let audio: [Float]           // 16kHz mono Float32
    let silenceBefore: Duration  // elapsed since last segment ended
    let duration: Duration
}

struct SpeechCaptureSnapshot {
    let audio: [Float]           // in-progress utterance audio
    let duration: Duration
}
```

Hides: AVFoundation setup, audio format config, VAD algorithm, buffer accumulation, threading. Callers never touch AVFoundation.

In PTT mode: `forceEnd()` overrides VAD on key release. In OPEN mode: VAD self-terminates segments. This difference is entirely internal.

---

### HotkeyManager

```swift
protocol HotkeyManager {
    var events: AsyncStream<HotkeyEvent> { get }
}

enum HotkeyEvent {
    case pttBegan
    case pttEnded(mode: InputMode)
    case modeToggled
}

enum InputMode {
    case dictation  // normal — inject on speech end
    case command    // modifier held — parse as vocabulary only, no injection
}
```

Hides: NSEvent global monitors, modifier key tracking, KeyboardShortcuts integration, Accessibility permissions. Callers receive resolved intent of key combinations only.

---

### Transcriber

```swift
protocol Transcriber {
    func transcribePartial(_ snapshot: SpeechCaptureSnapshot) async -> String
    func transcribe(_ segment: SpeechSegment) async -> TranscriptionResult
}

struct TranscriptionResult {
    let text: String
    let confidence: Float
    let segment: SpeechSegment  // timing carried through for IntentResolver
}
```

Hides: WhisperKit initialization, model loading, shared in-flight load coordination, background prewarm, Core ML scheduling, model path resolution, and snapshot decoding. Callers submit in-progress capture snapshots for live HUD transcript updates and receive a single final result when an utterance completes.

---

### IntentResolver

```swift
protocol IntentResolver {
    func resolve(_ result: TranscriptionResult, mode: InputMode) -> Intent
}

enum Intent {
    case inject(String)
    case command(Command)
    case discard            // confidence below threshold, or noise
}

enum Command {
    case roger  // send Return only — text already in terminal
    case abort  // clear terminal buffer + clear HUD
}
```

Hides: isolation timing algorithm, all threshold constants, vocabulary matching, confidence floor. Callers receive only the resolved intent.

---

### OutputManager

```swift
protocol OutputManager {
    func append(_ text: String)  // ZLE BUFFER += text, cursor at end
    func send()                  // CGEvent Return keystroke
    func clear()                 // ZLE BUFFER = ""
}
```

Hides: session registry lookup, recent-session activity ranking, process tree walking, pipe path resolution, ZLE wire protocol, shell pipe I/O. Three operations, no implementation details exposed.

`SessionController` always sequences these operations. They are never chained inside `OutputManager`.

Each `append` call concatenates to the existing ZLE buffer (space-separated). `clear` resets to empty. This is the only mutation model — there is no replace operation.

When session discovery or pipe delivery fails, `OutputManager` must emit explicit diagnostics identifying the frontmost app, candidate shell PID ancestry, resolved pipe path, recent-activity ranking when multiple shells are present, and whether the failure was lookup, stale registry, open, or write.

---

### SessionController (coordinator)

The only module that knows all others. It translates runtime events into output actions.

```text
1) pttEnded(.dictation)
   pipeline: transcribe -> resolve
   outcomes:
   - .inject(t) -> output.append(t)
   - .discard   -> no-op

2) pttEnded(.command)
   pipeline: transcribe -> resolve
   outcomes:
   - .command(.roger) -> output.send()
   - .command(.abort) -> output.clear()
   - .discard         -> no-op

3) OPEN segment
   pipeline: transcribe -> resolve
   outcomes:
   - .inject(t) -> output.append(t)
   - .discard   -> no-op

4) OPEN isolated command
   pipeline: transcribe -> resolve
   outcomes:
   - .command(.roger) -> output.send()
   - .command(.abort) -> output.clear()
   - .discard         -> no-op
```

---

### HUD

Pure observer of `SessionController` state. No interface — subscribes to published state:

```
.recording    → show live partial transcription text for the current utterance
.transcribing → show activity indicator
.injected     → fade out (text now in terminal)
.cleared      → dismiss immediately
.idle         → hidden
```

The HUD behavior must be consistent across PTT and OPEN mode. The only difference between modes is what ends the utterance:
- PTT: key release
- OPEN: silence detection

Floating `NSWindow`, level `.floating`, `canBecomeKey = false`, click-through. Never steals focus from target application.

---

## 9. Shell Integration

### Mechanism

ZLE file descriptor watcher. Terminal-emulator agnostic — works in Ghostty, Terminal.app, iTerm2, VS Code integrated terminal, Obsidian terminal plugin, Zellij/tmux panes, or any emulator running zsh.

### Shell Snippet (installed to ~/.zshrc)

```zsh
# Egregore integration — managed by Egregore.app
VOICE_PIPE="/tmp/egregore-$$.pipe"
VOICE_REGISTRY="$HOME/.config/egregore/sessions"
VOICE_DEBUG="${EGREGORE_SHELL_DEBUG:-0}"
VOICE_DEBUG_LOG="${EGREGORE_SHELL_DEBUG_LOG:-$HOME/.local/share/egregore/logs/shell-integration.log}"

_egregore_debug() {
    [[ "$VOICE_DEBUG" == "1" ]] || return 0
    mkdir -p "${VOICE_DEBUG_LOG:h}"
    print -r -- "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] [shell] $1" >> "$VOICE_DEBUG_LOG"
}

mkfifo "$VOICE_PIPE" 2>/dev/null
exec {VOICE_FD}<>"$VOICE_PIPE"
mkdir -p "$VOICE_REGISTRY"
echo "$VOICE_PIPE" > "$VOICE_REGISTRY/$$"
trap "rm -f '$VOICE_REGISTRY/$$' '$VOICE_PIPE'" EXIT
typeset -g EGREGORE_PENDING_ACTION=""
typeset -g EGREGORE_PENDING_TEXT=""
_egregore_debug "registered pid=$$ pipe=$VOICE_PIPE registry=$VOICE_REGISTRY fd=$VOICE_FD"

_egregore_apply_pending() {
    case $EGREGORE_PENDING_ACTION in
        inject)
            BUFFER="${BUFFER:+$BUFFER }$EGREGORE_PENDING_TEXT"
            CURSOR=${#BUFFER}
            zle -R
            _egregore_debug "inject applied after_len=${#BUFFER} after_buffer<<<$BUFFER>>> after_cursor=$CURSOR"
            ;;
        clear)
            BUFFER=""
            CURSOR=0
            zle -R
            _egregore_debug "clear applied after_len=${#BUFFER} after_buffer<<<$BUFFER>>> after_cursor=$CURSOR"
            ;;
    esac
}

_egregore_inject() {
    local action text
    local before_buffer="$BUFFER"
    local before_cursor="$CURSOR"
    _egregore_debug "handler entry fd=$VOICE_FD before_len=${#before_buffer} before_buffer<<<$before_buffer>>> before_cursor=$before_cursor"
    IFS='|' read -r action text <&$VOICE_FD || return 1
    EGREGORE_PENDING_ACTION="$action"
    EGREGORE_PENDING_TEXT="$text"
    zle _egregore_apply_pending
}

zle -N _egregore_apply_pending
zle -N _egregore_inject
zle -F $VOICE_FD _egregore_inject
# End Egregore integration
```

### Session Discovery (inside OutputManager)

1. `NSWorkspace.shared.frontmostApplication` → focused app PID
2. Walk process tree to find shell child with a registered session file
3. Read pipe path from `~/.config/egregore/sessions/{pid}`
4. Write `inject|{text}\n` or `clear|\n` to pipe

### Install Flow

App presents a one-time "Install Shell Integration" prompt on first launch. Appends the snippet to `~/.zshrc` with explicit confirmation. Displays exactly what will be written and where. Uninstall: remove the marked block from `~/.zshrc` and delete `~/.config/egregore/`.

When `EGREGORE_SHELL_DEBUG=1`, the shell snippet may write handler diagnostics to `EGREGORE_SHELL_DEBUG_LOG` for manual debugging and PTY-backed integration tests.

---

## 10. Model

| Property | Value |
|---|---|
| Format | Core ML (`.mlmodelc`) — not GGML |
| Model | `openai_whisper-large-v3_turbo` |
| Source | `argmaxinc/whisperkit-coreml` on HuggingFace |
| Storage | `~/.local/share/egregore/models/` |
| Init | Lazy — loads on first transcription, not app launch |
| Swappable | Yes — `Transcriber` protocol decouples model from all callers |

First utterance triggers download + compile if model is absent. HUD shows download progress. Subsequent launches are instant after first-transcription warmup.

---

## 11. Test Philosophy

Tests are **proof that the implementation satisfies the spec**. They are the primary feedback loop for agentic contributors. Not documentation, not safety net — proof.

### What Gets Tested

**Property-based tests** for logic modules:

- `IntentResolver`: for any transcription matching vocabulary text, with `silenceBefore > 1500ms` and `duration < 2000ms`, `resolve()` always returns `.command(_)` — never `.inject`, never `.discard`
- `IntentResolver`: for any non-vocabulary text regardless of timing, `resolve()` never returns `.command(_)`
- `IntentResolver`: for any transcription with confidence below threshold, `resolve()` always returns `.discard`
- `OutputManager` (mocked pipe): any sequence of `append` calls followed by `clear` always results in empty buffer regardless of text content, length, or unicode composition
- `OutputManager` (mocked pipe): multiple `append` calls always produce space-separated concatenation in pipe write order
- Interactive zsh PTY: the managed shell snippet receives FIFO events and logs post-mutation shell state for at least the `inject` path
- Interactive zsh PTY: shell debug logging proves handler entry, parsed action, and post-mutation buffer state without requiring microphone hardware

**End-to-end tests** for the pipeline (no hardware required — all inputs mocked):

- Synthesized `SpeechSegment` with known audio → `Transcriber` → expected text output
- Partial transcript stream for an active utterance → HUD state reflects incrementally updated text
- Known `TranscriptionResult` with timing metadata → `IntentResolver` → expected `Intent` for all cases
- `Intent` sequence → `OutputManager` (mock shell) → expected pipe writes in correct order and format
- Full pipeline: mock `AudioPipeline` emitting known segments → expected shell pipe output
- Real interactive `zsh` running on a PTY with the managed snippet installed → expected shell debug log entries and post-mutation buffer state after pipe writes

### What Does Not Get Tested

- `AVFoundation` behavior (Apple's responsibility)
- WhisperKit transcription accuracy (Argmax's responsibility)
- UI layout and HUD appearance
- NSEvent/hotkey delivery timing

### Test as Spec Enforcement

Each E2E test maps to a named spec feature. A passing test suite is a verifiable claim that the feature works as specified. Tests must be runnable in CI without microphone hardware.

---

## 12. Coding Guidelines

- Comments are acceptable but minimal. Code must be self-documenting. Comment only where intent cannot be inferred from naming and structure.
- Do not split functions for brevity alone. Split only when the result is a deeper interface with better information hiding.
- No shallow helper functions. A method that merely renames another method's call is noise.
- Protocols over concrete types at module boundaries. Concrete types inside modules.
- `actor` for any mutable state shared across async contexts. `@MainActor` only for UI updates.
- Error handling: `precondition`/`fatalError` for programmer errors, graceful recovery for runtime failures (model download failure, pipe write failure, missing session).

---

## 13. Incremental Build Milestones

Each milestone is independently verifiable. Milestones 1–3 require no hardware.

| # | Milestone | Verifiable by |
|---|---|---|
| 1 | Write known string to `OutputManager`, verify the shell handler mutates live editor state for injection via pipe, and confirm append/clear behavior manually | PTY integration test plus shell observation, no audio |
| 2 | Pass hardcoded `[Float]` through `WhisperKitTranscriber`, receive non-empty text | Unit assertion, no mic |
| 3 | Feed mock `TranscriptionResult` into `IntentResolver`, verify correct `Intent` for all branches | Property-based test suite |
| 4 | `AVAudioEngine` tap running, `SpeechSegment` emitted correctly on real speech with VAD silence detection | Mic required |
| 5 | PTT full path: hold key → speak → release → text appears in terminal buffer | Hardware E2E |
| 6 | OPEN mode: isolated ROGER/ABORT route to commands, normal speech injects after silence finalization | Hardware E2E |
| 7 | HUD: appears on record, shows live transcript text during capture, and dismisses correctly for all exit paths | Visual verification |
| 8 | Shell integration installer: prompt, snippet written to `.zshrc`, registry operational across multiple sessions | Integration test |
