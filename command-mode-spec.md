# Egregore — Interpreted Command Mode Specification

*2026-03-14*
#voice-control #terminal #llm #shell #spec

---

## 0. Relationship To Root Spec

This document defines the detailed behavior for Egregore's `Interpreted Command` mode.
[`specs.md`](/Users/christopher/projects/egregore/specs.md) remains the top-level source of truth for the product.
When this file and the root spec overlap, they must agree.

---

## 1. Problem Statement

Literal speech transcription is a poor direct medium for shell commands.
Common command tokens, flags, shell operators, and quoted arguments are routinely mistranscribed by ASR:

- `git` -> `good` / `get`
- `gh` -> `G H`
- spoken punctuation and shell structure -> natural-language transcript fragments

This makes raw transcript-to-shell injection unreliable for direct terminal control even when the underlying speech-to-text quality is reasonable.

`Interpreted Command` mode addresses this by inserting an LLM normalization step between finalized speech transcription and shell-buffer mutation.

---

## 2. Feature Summary

`Interpreted Command` mode is a second toggleable microphone mode alongside `Literal Dictation`.

Runtime path:

```text
utterance
  -> Whisper transcription
  -> command-word bypass check
  -> LLM command normalization
  -> replace shell buffer with normalized single-line command
```

There is no intermediary confirmation UI step inside Egregore.
The shell remains the confirmation surface:

- user sees the resulting command in the terminal buffer
- `ROGER` submits it
- `ABORT` clears it
- user may speak again to replace it

No output from this mode is auto-submitted.

---

## 3. User Experience Contract

### Activation

| Action | Key | Mechanism |
|---|---|---|
| Toggle interpreted command mode on/off | `Right Control (^)` + `Shift` tap | `NSEvent flagsChanged` |

This is a toggle, not hold-to-talk.
Turning the mode on opens the mic.
Turning it off closes the mic and returns the HUD to idle.

### Core behavior

- Every finalized non-command utterance is sent through the LLM pass
- The resulting command replaces the entire current shell buffer
- Live partial transcript display is not required in this mode
- HUD must visibly indicate that `Interpreted Command` mode is active
- HUD only needs to show the current mode, not raw transcript text or interpreted command text

### Voice commands

The following commands bypass the LLM pass entirely:

| Word | Meaning |
|---|---|
| `ROGER` | Submit the current shell buffer exactly as-is |
| `ABORT` | Clear the current shell buffer |

These commands are global across both voice modes and retain identical behavior.

Future command vocabulary may expand, but only `ROGER` and `ABORT` are in scope for this feature.

---

## 4. LLM Normalization Contract

### Purpose

The LLM's job is to convert a finalized spoken transcript into the shell command the user most likely intended.
It is a command normalizer, not an autonomous agent.

### Input

V1 input is transcript only.

No additional context is provided:

- no current shell buffer
- no working directory
- no shell history
- no repository context
- no filesystem context

### Output

V1 output must be exactly one single-line shell command.

Constraints:

- single-line only
- no markdown
- no backticks
- no explanatory prose
- no bullet lists
- no assistant framing
- may include shell metacharacters and syntax if they reflect user intent

Allowed examples include:

- pipes
- redirects
- quotes
- environment assignments
- flags
- command chaining
- command substitution

Not allowed in V1:

- multiline shell
- heredocs
- multiple output alternatives

### Non-goals

The model must not:

- execute tasks
- invent broader workflows
- emit explanations as primary output
- require a second in-app confirmation step

There is no extra destructive-command safety policy in V1 beyond the fact that Egregore injects into the shell buffer and does not auto-send.

---

## 5. Model And API Assumptions

V1 target stack:

| Property | Value |
|---|---|
| Provider | OpenAI |
| API surface | Responses API |
| Model | `gpt-5-mini` |
| State | Stateless request/response |
| Persistence | `store: false` |
| Credentials | macOS Keychain |

The app must treat missing credentials as a recoverable runtime configuration problem, not a crash-worthy error.

---

## 6. Module Contract

Add a dedicated interpreter module boundary:

```swift
protocol CommandInterpreter {
    func interpret(_ transcript: String) async -> CommandInterpretationResult
}

struct CommandInterpretationResult {
    let command: String
    let confidence: Float?
    let warning: String?
}
```

The protocol hides:

- provider-specific request formatting
- OpenAI networking
- prompt construction
- response parsing
- output validation
- credential lookup

Callers receive only validated shell-normalization results.

If interpretation fails, the caller receives an explicit failure result or error surface suitable for HUD/runtime diagnostics.

---

## 7. Output Semantics

`Interpreted Command` mode does not append.
It replaces the current shell buffer on every successful interpreted utterance.

`OutputManager` therefore requires replace semantics:

```swift
protocol OutputManager {
    func append(_ text: String) -> OutputResult
    func replaceBuffer(with text: String) -> OutputResult
    func send() -> OutputResult
    func clear() -> OutputResult
}
```

Required behavior:

- prompt-ready shell path: replace by clearing buffer then injecting normalized command through the shell pipe
- fallback path: replace by issuing synthetic clear then synthetic typed text against the focused terminal
- replacement is atomic from the caller's point of view even if implemented as clear-plus-inject internally

On interpreter failure, validation failure, or transport failure, the existing shell buffer must remain unchanged unless a replace operation has already begun.

---

## 8. SessionController Behavior

`SessionController` remains the only coordinator.

For interpreted mode:

```text
toggle interpreted mode on
  -> pipeline.start()
  -> HUD shows interpreted command mode active

finalized utterance arrives
  -> transcribe final segment
  -> resolve command vocabulary
  -> if ROGER/ABORT: bypass interpreter and dispatch existing output action
  -> else: interpret transcript via CommandInterpreter
  -> validate single-line command result
  -> output.replaceBuffer(with: command)
  -> HUD shows short success/failure state, then returns to interpreted listening state while mic stays open

toggle interpreted mode off
  -> pipeline.stop()
  -> HUD idle
```

Partial transcript streaming remains part of literal mode and does not need to drive HUD behavior in interpreted mode.

---

## 9. HUD And Menu Bar Requirements

HUD requirements for V1:

- clearly show when interpreted mode is active
- distinguish interpreted mode from literal dictation mode
- show interpreting/error/success transitions as needed
- do not require display of transcript text or normalized command text

Menu bar requirements for V1:

- show both mode bindings in user-facing language
- show whether interpreted mode is configured and available
- expose API-key setup/update flow

Current mode visibility is required.
Verbose transcript/result introspection is not required.

---

## 10. Keychain Requirements

The OpenAI API key must be stored in macOS Keychain.

Requirements:

- user can save or update the key from the app
- app can detect whether a key is present
- app does not display the raw key after storage
- missing or invalid key produces explicit diagnostics and user-facing setup guidance

Environment variables are not the primary UX for this feature.

---

## 11. Failure Handling

Failures must be visible and diagnosable.

At minimum log and surface:

- missing API key
- network/request failure
- invalid model response shape
- multiline response rejection
- empty response rejection
- shell buffer replacement failure

Failure must not silently degrade into literal append behavior.
Interpreted mode either replaces the shell buffer with the normalized command or reports failure.

---

## 12. Tests As Proof

Required proof for this feature:

- hotkey tests proving interpreted-mode binding is distinct from literal mode
- coordinator tests proving finalized utterances in interpreted mode always call the interpreter unless they resolve to `ROGER` or `ABORT`
- coordinator tests proving interpreted results replace, not append, the shell buffer
- output-manager tests proving replace semantics on both pipe and fallback paths
- interpreter tests proving response validation rejects multiline output, empty output, and chatty wrappers
- HUD tests proving interpreted mode has distinct visible state from literal mode

Hardware/network independence:

- default automated tests must not require microphone hardware
- default automated tests must not require live OpenAI credentials or network access

---

## 13. Out Of Scope For V1

- multiline shell generation
- repo-aware interpretation
- shell-history-aware interpretation
- autonomous execution
- extra destructive-command policy
- in-app command diff/review UI
- user-configurable prompt templates

These may be added later, but are not implied by this feature.
