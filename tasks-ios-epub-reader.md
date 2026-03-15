# iOS Epub Reader — Implementation Tasks

## Design Decisions

These choices apply APOSD principles. Future contributors should understand the *why* before changing the *what*.

**No ZipExtractor protocol.** Zip extraction is a single private function inside EpubParser. A protocol for one call site is a shallow module — it adds interface surface without hiding complexity. The zip code lives where it's used.

**BookReadingSession is the key abstraction.** The read loop (iterate chapters → iterate paragraphs → speak → handle controls) is significant complexity that both CLI and iOS need. Extracting it into an actor with a simple interface (play/pause/skip + AsyncStream events) creates a deep module. Callers never manage paragraph iteration or speaker coordination.

**Platform differences pulled downward.** `#if os(iOS)` lives inside Speaker (audio session) and EpubParser (zip method), never in callers. The public interfaces are identical across platforms.

**Same repo, shared library.** EgregoreReadLib compiles for macOS + iOS. The CLI and iOS app are thin platform-specific shells on top. This enables future iOS capabilities (voice memos → Obsidian) to share infrastructure.

---

## Task 1
- desc: Replace Process-based epub unzip with pure-Swift zip extraction using the Compression framework so EpubParser works on iOS
- deps: none
- passes: false
- ac:
  - EpubParser no longer uses Process or /usr/bin/unzip
  - Zip extraction handles both stored (uncompressed) and deflated entries
  - Extraction is a private implementation detail inside EpubParser with no new public API surface
  - All existing EpubParserTests pass without modification
- verify: swift test --filter EgregoreReadTests

## Task 2
- desc: Add a parse(data:) overload to EpubParser so callers can pass epub bytes directly without requiring a file path
- deps: Task 1
- passes: false
- ac:
  - EpubParser exposes `public static func parse(data: Data) throws -> EpubBook`
  - The existing `parse(path:)` delegates to `parse(data:)` internally
  - DRM detection, container parsing, spine resolution, and chapter extraction all work identically through both entry points
  - A new test verifies parse(data:) produces the same result as parse(path:) for the same epub
- verify: swift test --filter EgregoreReadTests

## Task 3
- desc: Add iOS audio session configuration to Speaker so TTS works with background playback, lock screen, and AirPods
- deps: none
- passes: false
- ac:
  - On iOS, Speaker lazily configures AVAudioSession with playback category and voicePrompt mode before the first utterance
  - On macOS, no AVAudioSession code executes (platform conditional compilation)
  - The Speaker public interface is unchanged
- verify: swift build --product egregore-read

## Task 4
- desc: Create BookReadingSession actor that extracts the epub read loop into a reusable orchestration layer for both CLI and iOS
- deps: none
- passes: false
- ac:
  - BookReadingSession accepts an EpubBook, Speaker, and start position, then drives the paragraph-by-paragraph read loop internally
  - The actor exposes play/pause/resume/stop/nextChapter/previousChapter and emits chapter and paragraph change events via AsyncStream
  - Chapter navigation stops the current utterance and repositions correctly including boundary checks
  - The event stream follows the same AsyncStream pattern used by Egregore's SessionController
- verify: swift test --filter EgregoreReadTests

## Task 5
- desc: Refactor the macOS CLI to use BookReadingSession instead of inlining the read loop in main.swift
- deps: Task 4
- passes: false
- ac:
  - main.swift delegates all reading orchestration to BookReadingSession
  - Keyboard controls (space/n/p/q) call session methods instead of directly manipulating Speaker
  - The --print flag consumes BookReadingSession events to print paragraph text
  - End-to-end CLI behavior is identical to before the refactor
- verify: swift build --product egregore-read && manual test with an epub

## Task 6
- desc: Update Package.swift to support both macOS and iOS platforms and add the iOS app executable target
- deps: Task 1, Task 2, Task 3
- passes: false
- ac:
  - Package.swift declares platforms for both macOS 14+ and iOS 17+
  - EgregoreReadLib compiles for both platforms without errors
  - A new EgregoreReadiOS executable target is declared with a dependency on EgregoreReadLib
  - The macOS CLI and Egregore main app targets continue to build
- verify: swift build --product egregore-read && swift build --product EgregoreReadiOS

## Task 7
- desc: Build the iOS SwiftUI app with file import, playback controls, and chapter progress display
- deps: Task 4, Task 6
- passes: false
- ac:
  - The app uses .fileImporter to pick .epub files from the Files app
  - A ReadingViewModel owns the BookReadingSession and publishes state for the UI
  - The UI displays book title, current chapter name and progress, and play/pause/prev/next controls
  - Tapping controls delegates to BookReadingSession methods through the view model
- verify: Build and run in iOS Simulator, import an epub, verify playback and controls

## Task 8
- desc: Add Now Playing and remote command integration so playback is controllable from lock screen, Control Center, and AirPods
- deps: Task 7
- passes: false
- ac:
  - MPRemoteCommandCenter handlers for play, pause, nextTrack, and previousTrack delegate to BookReadingSession
  - MPNowPlayingInfoCenter displays the book name and current chapter title
  - Now playing info updates on chapter changes
  - Background audio continues when the app is backgrounded or the screen is locked
  - Info.plist declares UIBackgroundModes audio
- verify: Deploy to device, start playback, lock screen, verify lock screen controls and AirPods play/pause

## Task 9
- desc: Add tests for BookReadingSession orchestration and pure-Swift zip extraction covering chapter navigation, pause/resume, and edge cases
- deps: Task 1, Task 4
- passes: false
- ac:
  - BookReadingSession tests verify chapter forward/backward navigation including boundary clamping
  - BookReadingSession tests verify pause and resume state transitions emit correct events
  - Zip extraction tests verify both stored and deflated entries extract correctly
  - parse(data:) test verifies byte-level epub parsing matches file-based parsing
  - All existing EpubParserTests and PageListResolverTests continue to pass
- verify: swift test
