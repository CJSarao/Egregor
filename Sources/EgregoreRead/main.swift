import Foundation

// MARK: - Arg parsing

struct Config {
    let epubPath: String
    var chapter: Int?
    var page: Int?
    var rate: Float = AVSpeechUtteranceDefaultSpeechRate
    var printText = false
}

func parseArgs() -> Config? {
    let args = CommandLine.arguments.dropFirst()
    guard let path = args.first else {
        printUsage()
        return nil
    }

    var config = Config(epubPath: path)
    var iter = args.dropFirst().makeIterator()
    while let arg = iter.next() {
        switch arg {
        case "--chapter":
            guard let val = iter.next(), let n = Int(val), n > 0 else {
                fputs("Error: --chapter requires a positive integer\n", stderr)
                return nil
            }
            config.chapter = n
        case "--page":
            guard let val = iter.next(), let n = Int(val), n > 0 else {
                fputs("Error: --page requires a positive integer\n", stderr)
                return nil
            }
            config.page = n
        case "--rate":
            guard let val = iter.next(), let r = Float(val), r > 0, r <= 1.0 else {
                fputs("Error: --rate requires a value between 0.0 (exclusive) and 1.0\n", stderr)
                return nil
            }
            config.rate = r
        case "--print":
            config.printText = true
        case "--help", "-h":
            printUsage()
            return nil
        default:
            fputs("Unknown option: \(arg)\n", stderr)
            printUsage()
            return nil
        }
    }
    return config
}

func printUsage() {
    let usage = """
    Usage: egregore-read <file.epub> [options]

    Options:
      --chapter N   Start from chapter N (1-based)
      --page N      Start from page N (requires page-list in epub)
      --rate R      Speech rate 0.0-1.0 (default: system)
      --print       Print text to terminal as it's spoken

    Controls:
      space         Pause / resume
      n             Next chapter
      p             Previous chapter
      q             Quit
    """
    print(usage)
}

// MARK: - Terminal raw mode

import Darwin

private var originalTermios = termios()

func enableRawMode() {
    tcgetattr(STDIN_FILENO, &originalTermios)
    var raw = originalTermios
    raw.c_lflag &= ~UInt(ICANON | ECHO)
    raw.c_cc.16 = 1  // VMIN
    raw.c_cc.17 = 0  // VTIME
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
}

func disableRawMode() {
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &originalTermios)
}

func readKey() -> UInt8? {
    var fds = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
    let ready = poll(&fds, 1, 0)
    guard ready > 0, fds.revents & Int16(POLLIN) != 0 else { return nil }
    var byte: UInt8 = 0
    let n = read(STDIN_FILENO, &byte, 1)
    return n == 1 ? byte : nil
}

// MARK: - Signal handling

func installSignalHandlers() {
    signal(SIGINT) { _ in
        disableRawMode()
        exit(0)
    }
    signal(SIGTERM) { _ in
        disableRawMode()
        exit(0)
    }
}

// MARK: - Main

import AVFoundation

enum Command {
    case none, pause, resume, nextChapter, prevChapter, quit
}

func run() async {
    guard let config = parseArgs() else { return }

    let book: EpubBook
    do {
        book = try EpubParser.parse(path: config.epubPath)
    } catch {
        fputs("Error: \(error)\n", stderr)
        return
    }

    guard !book.chapters.isEmpty else {
        fputs("Error: No readable chapters found\n", stderr)
        return
    }

    // Resolve start position
    var startChapter = 0
    var startParagraph = 0

    if let page = config.page {
        guard let pageList = book.pageList else {
            fputs("Error: This epub has no page-list navigation. Use --chapter instead.\n", stderr)
            return
        }
        guard let pos = PageListResolver.resolve(page: page, in: pageList) else {
            fputs("Error: Page \(page) not found in page-list\n", stderr)
            return
        }
        startChapter = pos.chapterIndex
        startParagraph = pos.paragraphIndex
    } else if let ch = config.chapter {
        startChapter = ch - 1  // 1-based → 0-based
        guard startChapter >= 0 && startChapter < book.chapters.count else {
            fputs("Error: Chapter \(ch) out of range (1-\(book.chapters.count))\n", stderr)
            return
        }
    }

    let speaker = Speaker()
    speaker.rate = config.rate

    installSignalHandlers()
    enableRawMode()
    defer { disableRawMode() }

    print("Reading: \(config.epubPath)")
    print("Chapters: \(book.chapters.count) | Controls: space=pause n=next p=prev q=quit\r")

    var chapterIdx = startChapter

    outer: while chapterIdx < book.chapters.count {
        let chapter = book.chapters[chapterIdx]
        let chapterNum = chapterIdx + 1
        let label = chapter.title ?? "Chapter \(chapterNum)"
        print("\r\n--- \(label) (\(chapterNum)/\(book.chapters.count)) ---\r")

        let paraStart = (chapterIdx == startChapter) ? startParagraph : 0

        for paraIdx in paraStart..<chapter.paragraphs.count {
            let text = chapter.paragraphs[paraIdx]
            if config.printText {
                print("\r\n\(text)\r")
            }

            // Speak in a task so we can poll keys concurrently
            let speakTask = Task { await speaker.speak(text) }

            // Poll keyboard while speaking
            while !speakTask.isCancelled {
                if let key = readKey() {
                    switch key {
                    case 0x20:  // space
                        if speaker.isPaused {
                            speaker.resume()
                            print("\r[resumed]\r")
                        } else {
                            speaker.pause()
                            print("\r[paused]\r")
                        }
                    case UInt8(ascii: "n"):
                        speaker.stop()
                        speakTask.cancel()
                        chapterIdx += 1
                        if chapterIdx >= book.chapters.count {
                            print("\r\nReached end of book.\r")
                            break outer
                        }
                        continue outer
                    case UInt8(ascii: "p"):
                        speaker.stop()
                        speakTask.cancel()
                        chapterIdx = max(0, chapterIdx - 1)
                        continue outer
                    case UInt8(ascii: "q"):
                        speaker.stop()
                        print("\r\nStopped.\r")
                        break outer
                    default:
                        break
                    }
                }
                try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms poll
            }

            await speakTask.value
        }

        chapterIdx += 1
    }

    if chapterIdx >= book.chapters.count {
        print("\r\nFinished reading.\r")
    }
}

await run()
