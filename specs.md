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
| Hotkeys | `AppKit` / `NSEvent` | Global modifier-key monitoring |
| Shell integration | ZLE fd watcher (zsh) | Terminal-agnostic, shell-level |
| Session registry | `~/.config/egregore/sessions/` | Per-session pipe registration |
| Session activity | `~/.config/egregore/activity/` | Legacy compatibility timestamps used when richer shell metadata is unavailable |

### Dependencies Policy
Only WhisperKit is currently declared as a third-party dependency. Any additional dependency requires explicit justification against implementing the functionality directly.

---

## 5. Mode System

Single mode: toggle mic on/off with a dedicated hotkey.

### Toggle (Open Mic)
- Tap toggle key → mic records, VAD runs continuously, HUD shows `Listening` before speech begins, then replaces it with a live transcript for the current utterance as partials arrive
- When silence ends the utterance, finalize the transcript, keep the most recent transcript visible while finalizing, then inject the finalized text into the active terminal buffer
- Isolated command words trigger command parsing (see isolation algorithm below)
- Normal utterances append to terminal buffer after trailing terminal-recitation punctuation is stripped from the end of the utterance (`.`, `,`, `;`, `:`, `!`, `?`) — ABORT is the only way to clear
- Tap toggle key again → mic stops, HUD shows idle

### Default Hotkey

| Action | Key | Mechanism |
|---|---|---|
| Toggle mic on/off | `Right Control (^)` tap | `NSEvent flagsChanged` |

Right-side modifier key only. No conflicts with terminal control sequences, common IDE shortcuts, or macOS system shortcuts. Comfortable to reach without looking — suitable for treadmill use.

---

## 6. Command Vocabulary

Minimal, opinionated. Military-style to prevent false positives in normal speech.

| Command | Word | Action |
|---|---|---|
| Send | `ROGER` | Submit the focused shell's current ZLE buffer through the shell pipe. Does NOT re-inject text — text already present from prior injection. |
| Clear | `ABORT` | Clear ZLE BUFFER in focused terminal + clear HUD. |

Vocabulary is fixed. No user configuration.

---

## 7. Isolation Algorithm (command detection)

```
utterance arrives
  duration < 2000ms        AND
  endedBySilence == true             AND
  text matches command vocabulary
  → Intent.command(_)

else
  → Intent.inject(text)
```

The timing thresholds are compile-time constants inside the audio pipeline and `IntentResolver`. Not exposed to callers or users. May be tuned during initial UX development then fixed.

---

## 8. Module Contracts

### AudioPipeline

```swift
protocol AudioPipeline {
    func start() async
    func stop() async
    var segments: AsyncStream<SpeechSegment> { get }
    var captureSnapshots: AsyncStream<SpeechCaptureSnapshot> { get }
}

struct SpeechSegment {
    let audio: [Float]           // 16kHz mono Float32
    let silenceBefore: Duration  // elapsed since last segment ended
    let duration: Duration
    let trailingSilenceAfter: Duration  // silence accumulated after speech before emission
    let endedBySilence: Bool            // true only when VAD closed the utterance
}

struct SpeechCaptureSnapshot {
    let audio: [Float]           // in-progress utterance audio
    let duration: Duration
}
```

Hides: AVFoundation setup, audio format config, VAD algorithm, buffer accumulation, segment termination details, threading. Callers never touch AVFoundation.

VAD self-terminates segments when silence is detected. This is entirely internal.

---

### HotkeyManager

```swift
protocol HotkeyManager {
    var events: AsyncStream<HotkeyEvent> { get }
}

enum HotkeyEvent {
    case toggle
}
```

Hides: NSEvent global monitors, modifier key tracking, and Accessibility permissions. Callers receive a single toggle event.

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
    func resolve(_ result: TranscriptionResult) -> Intent
}

enum Intent {
    case inject(String)
    case command(Command)
    case discard            // confidence below threshold, or noise
}

enum Command {
    case roger  // submit current buffer only — text already in terminal
    case abort  // clear terminal buffer + clear HUD
}
```

Hides: isolation timing algorithm, all threshold constants, vocabulary matching, confidence floor. Callers receive only the resolved intent.

---

### OutputManager

```swift
protocol OutputManager {
    func append(_ text: String)  // ZLE BUFFER += text, cursor at end
    func send()                  // accept current ZLE buffer via shell pipe
    func clear()                 // ZLE BUFFER = ""
}
```

Hides: session registry lookup, focus/prompt-aware shell ranking, process tree walking, pipe path resolution, ZLE wire protocol, shell pipe I/O. Three operations, no implementation details exposed.

`SessionController` always sequences these operations. They are never chained inside `OutputManager`.

Each `append` call concatenates to the existing ZLE buffer (space-separated). `clear` resets to empty. This is the only mutation model — there is no replace operation.

When session discovery or pipe delivery fails, `OutputManager` must emit explicit diagnostics identifying the frontmost app, candidate shell PID ancestry, resolved pipe path, focus/prompt ranking when multiple shells are present, and whether the failure was lookup, stale registry, open, write, or ambiguity refusal.

---

### SessionController (coordinator)

The only module that knows all others. It translates runtime events into output actions.

```text
toggle → start recording
  pipeline: transcribe -> resolve
  outcomes:
  - .inject(t) -> normalize trailing terminal punctuation, output.append(t), return HUD to listening after a short final-state dwell
  - .command(.roger) -> output.send(), return HUD to listening after a short final-state dwell
  - .command(.abort) -> output.clear(), return HUD to listening after a short final-state dwell
  - .discard -> no-op, remain in listening state while mic stays open

toggle → stop recording
  pipeline.stop(), HUD idle
```

---

### HUD

Pure observer of `SessionController` state. No interface — subscribes to published state:

```
.listening    → show mic-open idle state before speech begins
.recording    → show live partial transcription text for the current utterance
.transcribing → keep the most recent transcript visible while finalizing when available; otherwise show activity indicator
.injected     → show submitted text briefly, then return to `.listening` if the mic is still open
.cleared      → show a short cleared state, then return to `.listening` if the mic is still open
.error        → show a short visible failure message, then return to `.listening` if the mic is still open
.idle         → hidden
```

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
VOICE_ACTIVITY="$HOME/.config/egregore/activity"
VOICE_DEBUG="${EGREGORE_SHELL_DEBUG:-0}"
VOICE_DEBUG_LOG="${EGREGORE_SHELL_DEBUG_LOG:-$HOME/.local/share/egregore/logs/shell-integration.log}"

_egregore_debug() {
    [[ "$VOICE_DEBUG" == "1" ]] || return 0
    mkdir -p "${VOICE_DEBUG_LOG:h}"
    print -r -- "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] [shell] $1" >> "$VOICE_DEBUG_LOG"
}

_egregore_mark_active() {
    mkdir -p "$VOICE_ACTIVITY"
    print -r -- "${EPOCHREALTIME:-0}" > "$VOICE_ACTIVITY/$$"
}

_egregore_write_session_state() {
    # Writes pipe path plus prompt/focus metadata for shell ranking.
}

_egregore_mark_prompt_ready() {
    _egregore_mark_active
    # Updates prompt/focus timestamps and marks the shell as eligible for send/clear.
    _egregore_write_session_state
}

_egregore_mark_busy() {
    _egregore_mark_active
    # Marks the shell as not currently at a prompt.
    _egregore_write_session_state
}

mkfifo "$VOICE_PIPE" 2>/dev/null
exec {VOICE_FD}<>"$VOICE_PIPE"
mkdir -p "$VOICE_REGISTRY"
_egregore_mark_prompt_ready
trap "exec {VOICE_FD}<&-; rm -f '$VOICE_REGISTRY/$$' '$VOICE_ACTIVITY/$$' '$VOICE_PIPE'" EXIT
typeset -g EGREGORE_PENDING_ACTION=""
typeset -g EGREGORE_PENDING_TEXT=""
_egregore_debug "registered pid=$$ pipe=$VOICE_PIPE registry=$VOICE_REGISTRY fd=$VOICE_FD"

_egregore_apply_pending() {
    case $EGREGORE_PENDING_ACTION in
        inject)
            BUFFER="${BUFFER:+$BUFFER }$EGREGORE_PENDING_TEXT"
            CURSOR=${#BUFFER}
            _egregore_mark_prompt_ready
            zle -R
            _egregore_debug "inject applied after_len=${#BUFFER} after_buffer<<<$BUFFER>>> after_cursor=$CURSOR"
            ;;
        clear)
            BUFFER=""
            CURSOR=0
            _egregore_mark_prompt_ready
            zle -R
            _egregore_debug "clear applied after_len=${#BUFFER} after_buffer<<<$BUFFER>>> after_cursor=$CURSOR"
            ;;
        send)
            _egregore_mark_prompt_ready
            zle -R
            zle -U $'\n'
            ;;
        *)
            _egregore_debug "unknown pending action=${EGREGORE_PENDING_ACTION:-<empty>}"
            ;;
    esac
}

_egregore_inject() {
    local action text line
    local before_buffer="$BUFFER"
    local before_cursor="$CURSOR"
    _egregore_debug "handler entry fd=$VOICE_FD before_len=${#before_buffer} before_buffer<<<$before_buffer>>> before_cursor=$before_cursor"
    IFS= read -r -t 1 line <&$VOICE_FD || {
        _egregore_debug "read failed fd=$VOICE_FD"
        return 0
    }
    [[ -z "$line" ]] && return 0
    action="${line%%|*}"
    text="${line#*|}"
    _egregore_debug "message action=${action:-<empty>} text_len=${#text} text<<<$text>>>"
    [[ -z "$action" ]] && return 0
    EGREGORE_PENDING_ACTION="$action"
    EGREGORE_PENDING_TEXT="$text"
    zle _egregore_apply_pending
}

zle -N _egregore_apply_pending
zle -N _egregore_inject
zle -F $VOICE_FD _egregore_inject
autoload -Uz add-zsh-hook add-zle-hook-widget
add-zsh-hook precmd _egregore_mark_prompt_ready
add-zsh-hook preexec _egregore_mark_busy
add-zle-hook-widget line-init _egregore_mark_prompt_ready
# End Egregore integration
```

### Session Discovery (inside OutputManager)

1. `NSWorkspace.shared.frontmostApplication` → focused app PID
2. Walk process tree to find shell child with a registered session file
3. Read pipe path plus prompt/focus metadata from `~/.config/egregore/sessions/{pid}`
4. Rank candidates by prompt/focus readiness before timestamp fallback
5. Write `inject|{text}\n`, `clear|\n`, or `send|\n` to pipe

This architecture targets the focused `zsh` line editor, not arbitrary child processes that currently own the terminal. When a full-screen CLI tool such as Codex or Claude Code has taken over the foreground TTY, Egregore can still target the underlying shell buffer but does not yet inject directly into the running child process.

### Install Flow

App presents a one-time "Install Shell Integration" prompt on first launch. Appends the snippet to `~/.zshrc` with explicit confirmation. Displays exactly what will be written and where. Uninstall: remove the marked block from `~/.zshrc` and delete `~/.config/egregore/`.

When `EGREGORE_SHELL_DEBUG=1`, the shell snippet may write handler diagnostics to `EGREGORE_SHELL_DEBUG_LOG` for manual debugging. PTY-backed integration proof remains deferred.

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

- `IntentResolver`: for any transcription matching vocabulary text, with `duration < 2000ms` and `endedBySilence == true`, `resolve()` always returns `.command(_)` — never `.inject`, never `.discard`
- `IntentResolver`: for any non-vocabulary text regardless of timing, `resolve()` never returns `.command(_)`
- `IntentResolver`: for any transcription with confidence below threshold, `resolve()` always returns `.discard`
- `OutputManager` (mocked pipe): any sequence of `append` calls followed by `clear` always ends with a final `clear|` message regardless of text content, length, or unicode composition
- `OutputManager` (mocked pipe): multiple `append` calls always produce ordered `inject|...` messages in pipe write order
- PTY-backed interactive `zsh` shell proof is deferred; current automated proof stops at mocked pipes plus shell-snippet installer coverage

**End-to-end tests** for the pipeline (no hardware required — all inputs mocked):

- Synthesized `SpeechSegment` with known audio → `Transcriber` → expected text output
- Partial transcript stream for an active utterance → HUD state reflects incrementally updated text
- Known `TranscriptionResult` with timing metadata → `IntentResolver` → expected `Intent` for all cases
- `Intent` sequence → `OutputManager` (mock shell) → expected pipe writes in correct order and format
- Full pipeline: mock `AudioPipeline` emitting known segments → expected shell pipe output
- Multi-step mocked flows: append, clear, append, and send outcomes through the same coordinator
- Deferred follow-up: real interactive `zsh` running on a PTY with the managed snippet installed

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
| 1 | Write known string to `OutputManager`, verify mocked pipe delivery and shell snippet install/debug surfaces | Automated today; PTY shell proof deferred |
| 2 | Pass hardcoded `[Float]` through `WhisperKitTranscriber`, receive non-empty text | Unit assertion, no mic |
| 3 | Feed mock `TranscriptionResult` into `IntentResolver`, verify correct `Intent` for all branches | Property-based test suite |
| 4 | `AVAudioEngine` tap running, `SpeechSegment` emitted correctly on real speech with VAD silence detection | Mic required |
| 5 | Toggle on → speak → VAD finalizes → text appears in terminal buffer | Hardware E2E |
| 6 | Isolated ROGER/ABORT route to commands, normal speech injects after silence finalization | Hardware E2E |
| 7 | HUD: appears on record, shows live transcript text during capture, and dismisses correctly for all exit paths | Visual verification |
| 8 | Shell integration installer: prompt, snippet written to `.zshrc`, registry operational across multiple sessions | Integration test |
