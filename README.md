# Egregore

> **Warning:** This project is a work in progress. Expect breaking changes and instability.

A macOS menu bar app that transcribes your voice and types it into the terminal. Built for hands-free shell interaction — say a command while walking on a treadmill and it appears in your zsh buffer.

Not a voice assistant. Not dictation software. A focused tool: voice goes in, text lands in your terminal.

## How It Works

```
hold Right Command → speak → release → text appears in terminal
```

Egregore captures audio, runs it through WhisperKit (on-device speech recognition via Apple's Neural Engine), decides what to do with the result, and writes it into your shell's line editor over a named pipe. Your terminal never loses focus.

Two modes:

- **PTT (Push-to-Talk)** — hold a key, speak, release. Default.
- **OPEN (Open Mic)** — VAD (voice activity detection) runs continuously. Speak freely, text flows into the terminal.

Two voice commands (military-style to avoid false positives):

| Say | What happens |
|---|---|
| `ROGER` | Presses Return — sends whatever's in the buffer |
| `ABORT` | Clears the buffer |

## Requirements

- macOS 14.0+ (Sonoma)
- Xcode 15+ / Swift 5.9+
- A microphone (for actual use — tests run without one)

## Build & Run

```bash
swift build
swift test       # 128 tests, no hardware needed
```

The binary lands in `.build/debug/Egregore`. On first transcription, WhisperKit downloads the Whisper model (~1 GB) to `~/.local/share/egregore/models/`.

## Project Structure

```
Package.swift                       # Swift Package Manager manifest
Sources/Egregore/
├── EgregoreApp.swift             # Entry point — menu bar app, no Dock icon
├── SessionController.swift         # The coordinator — connects everything
├── Domain/
│   ├── Protocols.swift             # 5 protocols defining module boundaries
│   └── Types.swift                 # Value types shared across modules
├── Audio/
│   └── AVAudioEnginePipeline.swift # Mic capture + voice activity detection
├── Hotkeys/
│   └── NSEventHotkeyManager.swift  # Global keyboard monitoring
├── Transcriber/
│   └── WhisperKitTranscriber.swift # Speech-to-text via WhisperKit
├── Resolver/
│   └── EgregoreIntentResolver.swift  # Decides: inject text, run command, or discard
├── Output/
│   └── ShellOutputManager.swift    # Writes to zsh's line buffer via named pipe
├── HUD/
│   └── HUDWindow.swift             # Floating overlay showing current state
├── MenuBar/
│   └── MenuBarView.swift           # Menu bar UI
└── ShellIntegration/
    └── ShellIntegrationInstaller.swift # Installs the zsh snippet into ~/.zshrc
Tests/EgregoreTests/              # 10 test files, 128 tests total
```

## Architecture (for the Curious)

This is a good codebase to study if you're learning Swift. It uses several patterns you'll encounter constantly in macOS/iOS work, and it's small enough to read end-to-end.

### Protocols as Module Boundaries

Open `Sources/Egregore/Domain/Protocols.swift` — five protocols, each under 10 lines:

```swift
protocol AudioPipeline {
    func start() async
    func stop() async
    func forceEnd() async
    var segments: AsyncStream<SpeechSegment> { get }
}

protocol Transcriber {
    func transcribe(_ segment: SpeechSegment) async -> TranscriptionResult
}

protocol IntentResolver {
    func resolve(_ result: TranscriptionResult, mode: InputMode) -> Intent
}

protocol OutputManager {
    func append(_ text: String)
    func send()
    func clear()
}
```

Each protocol hides a large amount of complexity behind a tiny surface. `AudioPipeline` hides AVFoundation audio graphs, format conversion, buffer management, and the VAD algorithm. Callers just see `start()`, `stop()`, and an async stream of speech segments.

**Why this matters:** In Swift, protocols are how you decouple modules and enable testing. `SessionController` depends on `any AudioPipeline`, not `AVAudioEnginePipeline` — so tests can inject a mock that emits fake segments without a microphone.

### Swift Concurrency in Practice

The project uses three concurrency primitives you should understand:

**`actor`** — SessionController and AVAudioEnginePipeline are both actors. An actor guarantees that only one piece of code accesses its mutable state at a time. No locks, no data races:

```swift
actor SessionController {
    private(set) var operatingMode: OperatingMode = .ptt
    private var pendingInputMode: InputMode?
    // Swift guarantees these are never read/written simultaneously
}
```

**`AsyncStream`** — The communication channel between modules. Instead of delegates or callbacks, each module exposes an `AsyncStream` that downstream consumers iterate with `for await`:

```swift
private func runSegmentLoop() async {
    for await segment in pipeline.segments {
        let result = await transcriber.transcribe(segment)
        let intent = resolver.resolve(result, mode: mode)
        dispatch(intent)
    }
}
```

This is the modern Swift replacement for delegate chains. The stream producer and consumer are fully decoupled.

**`nonisolated let`** — Streams are declared `nonisolated` on actors so callers can access them without `await`:

```swift
actor AVAudioEnginePipeline: AudioPipeline {
    nonisolated let segments: AsyncStream<SpeechSegment>
    // Safe because AsyncStream is Sendable and assigned once in init
}
```

### Dependency Injection Without Frameworks

No DI container, no property wrappers, no magic. Just init parameters:

```swift
actor SessionController {
    init(
        hotkeys: any HotkeyManager,
        pipeline: any AudioPipeline,
        transcriber: any Transcriber,
        resolver: any IntentResolver,
        output: any OutputManager
    ) { ... }
}
```

Tests create mock implementations and pass them in. The `any` keyword tells Swift to accept any type conforming to the protocol (existential type). This is the simplest DI pattern in Swift — learn it before reaching for frameworks.

### The `@main` Entry Point

The entire app setup is 9 lines:

```swift
@main
struct EgregoreApp: App {
    init() {
        NSApp.setActivationPolicy(.accessory)  // no Dock icon
    }

    var body: some Scene {
        MenuBarExtra("Egregore", systemImage: "waveform.badge.mic") {
            MenuBarView()
        }
    }
}
```

`@main` marks the entry point. `NSApp.setActivationPolicy(.accessory)` hides the app from the Dock — it lives entirely in the menu bar. `MenuBarExtra` is a SwiftUI scene type that creates a menu bar item.

### How the Shell Integration Works

This is the most interesting systems-level piece. Egregore doesn't simulate keystrokes to type text (fragile, slow). Instead, it writes directly into zsh's line editor (ZLE) via a named pipe:

1. A zsh snippet (installed into `~/.zshrc`) creates a named pipe per shell session
2. ZLE watches the pipe's file descriptor for incoming data
3. Egregore finds the active terminal's shell PID, looks up its pipe path, and writes `inject|hello world\n`
4. ZLE reads it and sets `BUFFER="hello world"` — text appears instantly

This is terminal-emulator agnostic. Works in any app running zsh: Ghostty, Terminal.app, iTerm2, VS Code terminal, tmux panes.

### Testing Without Hardware

Every module is testable without a microphone or audio output. The key pattern is **closure injection**:

```swift
// Production: installs a real AVAudioEngine tap
init(tapInstaller: @escaping TapInstaller = AVAudioEnginePipeline.makeLiveTapInstaller())

// Test: injects a no-op tap, then calls processChunk() directly
let pipeline = AVAudioEnginePipeline { callback in
    TapHandle(start: {}, stop: {})
}
await pipeline.processChunk(someFakeAudioData)
```

WhisperKitTranscriber uses the same pattern — a `@Sendable () async throws -> Engine` closure that tests replace with a stub returning canned results. 128 tests run in CI with zero hardware dependencies.

## Key Files to Read First

If you're studying this codebase, read in this order:

1. **`Domain/Types.swift`** — all the value types. Small file, sets up the vocabulary.
2. **`Domain/Protocols.swift`** — the five module contracts. Read these before any implementation.
3. **`Resolver/EgregoreIntentResolver.swift`** — the simplest implementation. Pure logic, no frameworks, no async. Good example of how a protocol gets implemented.
4. **`SessionController.swift`** — the coordinator. Shows how `actor`, `AsyncStream`, and `for await` work together.
5. **`Audio/AVAudioEnginePipeline.swift`** — the most complex module. Shows how to wrap a framework API behind a clean protocol.

## Dependencies

| Package | What it does | Why it's here |
|---|---|---|
| [WhisperKit](https://github.com/argmaxinc/WhisperKit) | On-device speech recognition using Core ML | The transcription engine |
| [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) | Global hotkey registration | Wraps NSEvent monitors for the mode toggle key |

Only these two. The project has a strict policy against adding dependencies — everything else is built with Apple's frameworks.

## License

Personal tool. Not currently licensed for distribution.
