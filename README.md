# Egregore

macOS menu bar app that transcribes speech and injects it into the active zsh session. Built for hands-free terminal use.

> Work in progress. Expect breaking changes.

## How it works

Tap Right Control to toggle the mic on. Speak. The HUD shows `Listening` before speech begins, then live transcript updates as partials arrive. Text appears in your terminal's zsh line buffer as VAD finalizes each utterance. Tap Right Control again to stop. Egregore prefers direct ZLE writes via a named pipe when the target shell is prompt-ready, and falls back to synthetic terminal key events when prompt readiness cannot be confirmed.

Two voice commands:

| Command | Action |
|---------|--------|
| `ROGER` | Submit the current shell buffer |
| `ABORT` | Clear the buffer |

Final dictation strips trailing terminal-recitation punctuation such as `git status.` -> `git status`.

## Requirements

- macOS 14.0+ (Sonoma)
- Xcode 15+ / Swift 5.9+
- Microphone (tests run without one)

## Build

```bash
swift build
swift test
```

On first launch, WhisperKit downloads the model (~1 GB) to `~/.local/share/egregore/models/`.

## Architecture

Five protocols define module boundaries (`Domain/Protocols.swift`). `SessionController` (an actor) coordinates all modules via `AsyncStream` channels. Dependencies are injected through init parameters — no frameworks.

```
Sources/Egregore/
├── SessionController.swift           # Coordinator
├── Domain/
│   ├── Protocols.swift               # AudioPipeline, Transcriber, IntentResolver, OutputManager, HotkeyManager
│   └── Types.swift                   # Shared value types
├── Audio/
│   └── AVAudioEnginePipeline.swift   # Mic capture, VAD, segment/snapshot streams
├── Hotkeys/
│   └── NSEventHotkeyManager.swift    # Global keyboard monitoring
├── Transcriber/
│   └── WhisperKitTranscriber.swift   # On-device STT via WhisperKit, streaming partials
├── Resolver/
│   └── EgregoreIntentResolver.swift  # Classify: inject text, command, or discard
├── Output/
│   └── ShellOutputManager.swift      # Named pipe writer, session discovery, shell targeting
├── HUD/
│   └── HUDWindow.swift               # Floating overlay (non-key, click-through)
└── ShellIntegration/
    └── ShellIntegrationInstaller.swift  # Managed zsh snippet lifecycle
```

### Shell integration

A managed zsh snippet (installed into `~/.zshrc`) creates a named pipe per session and registers prompt-ready metadata under `~/.config/egregore/sessions/`. ZLE watches the pipe fd. Egregore resolves the frontmost terminal, ranks descendant shells by prompt/focus readiness, and prefers writing `inject|`, `clear|`, or `send|` messages through that pipe. When a focused terminal is found but prompt readiness is not confirmed, it falls back to synthetic terminal key events. Terminal-emulator agnostic for shells running zsh.

Current limitation: when a child CLI tool is actively owning the terminal session, Egregore still targets the underlying zsh buffer rather than the foreground child process itself.

Shell-side debug logging available via `EGREGORE_SHELL_DEBUG=1`.

### Testing

All modules are testable without audio hardware. Closure injection replaces real audio taps and WhisperKit engines with stubs. Tests cover resolver logic, output semantics, HUD state transitions, streaming partials, and mocked end-to-end flows.

## Dependencies

| Package | Purpose |
|---------|---------|
| [WhisperKit](https://github.com/argmaxinc/WhisperKit) | On-device speech recognition (Core ML) |

Only third-party dependency.

## License

Personal tool. Not licensed for distribution.
