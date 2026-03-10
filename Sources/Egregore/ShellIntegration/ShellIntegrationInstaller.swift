import Foundation

struct ShellIntegrationInstaller {
    private static let beginMarker = "# BEGIN Egregore integration — managed by Egregore.app"
    private static let endMarker = "# END Egregore integration"

    // Swift multiline raw string: closing """# at 4-space indent strips 4 spaces from each content line
    static let snippet: String = #"""
    # BEGIN Egregore integration — managed by Egregore.app
    VOICE_PIPE="/tmp/egregore-$$.pipe"
    VOICE_REGISTRY="$HOME/.config/egregore/sessions"

    mkfifo "$VOICE_PIPE" 2>/dev/null
    exec {VOICE_FD}<>"$VOICE_PIPE"
    mkdir -p "$VOICE_REGISTRY"
    echo "$VOICE_PIPE" > "$VOICE_REGISTRY/$$"
    trap "rm -f '$VOICE_REGISTRY/$$' '$VOICE_PIPE'" EXIT

    _egregore_inject() {
        local action text
        IFS='|' read -r action text <&$VOICE_FD
        case $action in
            inject) BUFFER="${BUFFER:+$BUFFER }$text"; CURSOR=${#BUFFER}; zle redisplay ;;
            clear)  BUFFER=""; CURSOR=0; zle redisplay ;;
        esac
    }

    zle -N _egregore_inject
    zle -F $VOICE_FD _egregore_inject
    # END Egregore integration
    """#

    let zshrcURL: URL
    let registryURL: URL
    let egregoreConfigURL: URL

    init(
        zshrcURL: URL = URL.homeDirectory.appending(path: ".zshrc"),
        registryURL: URL = URL.homeDirectory.appending(path: ".config/egregore/sessions"),
        egregoreConfigURL: URL = URL.homeDirectory.appending(path: ".config/egregore")
    ) {
        self.zshrcURL = zshrcURL
        self.registryURL = registryURL
        self.egregoreConfigURL = egregoreConfigURL
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
        if fm.fileExists(atPath: egregoreConfigURL.path) {
            try fm.removeItem(at: egregoreConfigURL)
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
