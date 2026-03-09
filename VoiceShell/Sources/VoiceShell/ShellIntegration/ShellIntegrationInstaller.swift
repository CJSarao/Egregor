import Foundation

struct ShellIntegrationInstaller {
    private static let beginMarker = "# BEGIN VoiceShell integration — managed by VoiceShell.app"
    private static let endMarker = "# END VoiceShell integration"

    // Swift multiline raw string: closing """# at 4-space indent strips 4 spaces from each content line
    static let snippet: String = #"""
    # BEGIN VoiceShell integration — managed by VoiceShell.app
    VOICE_PIPE="/tmp/voiceshell-$$.pipe"
    VOICE_REGISTRY="$HOME/.config/voiceshell/sessions"

    mkfifo "$VOICE_PIPE" 2>/dev/null
    exec {VOICE_FD}<>"$VOICE_PIPE"
    mkdir -p "$VOICE_REGISTRY"
    echo "$VOICE_PIPE" > "$VOICE_REGISTRY/$$"
    trap "rm -f '$VOICE_REGISTRY/$$' '$VOICE_PIPE'" EXIT

    _voiceshell_inject() {
        local action text
        IFS='|' read -r action text <&$VOICE_FD
        case $action in
            inject) BUFFER="${BUFFER:+$BUFFER }$text"; CURSOR=${#BUFFER}; zle redisplay ;;
            clear)  BUFFER=""; CURSOR=0; zle redisplay ;;
        esac
    }

    zle -N _voiceshell_inject
    zle -F $VOICE_FD _voiceshell_inject
    # END VoiceShell integration
    """#

    let zshrcURL: URL
    let registryURL: URL
    let voiceshellConfigURL: URL

    init(
        zshrcURL: URL = URL.homeDirectory.appending(path: ".zshrc"),
        registryURL: URL = URL.homeDirectory.appending(path: ".config/voiceshell/sessions"),
        voiceshellConfigURL: URL = URL.homeDirectory.appending(path: ".config/voiceshell")
    ) {
        self.zshrcURL = zshrcURL
        self.registryURL = registryURL
        self.voiceshellConfigURL = voiceshellConfigURL
    }

    var isInstalled: Bool {
        guard let content = try? String(contentsOf: zshrcURL, encoding: .utf8) else { return false }
        return content.contains(Self.beginMarker)
    }

    func install() throws {
        try FileManager.default.createDirectory(at: registryURL, withIntermediateDirectories: true)
        guard !isInstalled else { return }

        let block = "\n\n" + Self.snippet + "\n"
        if FileManager.default.fileExists(atPath: zshrcURL.path) {
            let handle = try FileHandle(forWritingTo: zshrcURL)
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(Data(block.utf8))
        } else {
            try block.write(to: zshrcURL, atomically: true, encoding: .utf8)
        }
    }

    func uninstall() throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: voiceshellConfigURL.path) {
            try fm.removeItem(at: voiceshellConfigURL)
        }
        guard fm.fileExists(atPath: zshrcURL.path),
              let content = try? String(contentsOf: zshrcURL, encoding: .utf8),
              content.contains(Self.beginMarker) else { return }
        try removeBlock(from: content).write(to: zshrcURL, atomically: true, encoding: .utf8)
    }

    private func removeBlock(from content: String) -> String {
        var lines = content.components(separatedBy: "\n")
        guard let beginIdx = lines.firstIndex(where: { $0.hasPrefix(Self.beginMarker) }),
              let endIdx = lines[beginIdx...].firstIndex(where: { $0.hasPrefix(Self.endMarker) }) else {
            return content
        }
        let removeFrom = beginIdx > 0 && lines[beginIdx - 1].isEmpty ? beginIdx - 1 : beginIdx
        lines.removeSubrange(removeFrom...endIdx)
        return lines.joined(separator: "\n")
    }
}
