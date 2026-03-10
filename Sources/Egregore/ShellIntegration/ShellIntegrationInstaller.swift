import Foundation

struct ShellIntegrationInstaller {
    private static let beginMarker = "# BEGIN Egregore integration — managed by Egregore.app"
    private static let endMarker = "# END Egregore integration"

    // Swift multiline raw string: closing """# at 4-space indent strips 4 spaces from each content line
    static let snippet: String = #"""
    # BEGIN Egregore integration — managed by Egregore.app
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
            *)
                _egregore_debug "unknown pending action=${EGREGORE_PENDING_ACTION:-<empty>}"
                ;;
        esac
    }

    _egregore_inject() {
        local action text
        local before_buffer="$BUFFER"
        local before_cursor="$CURSOR"
        _egregore_debug "handler entry fd=$VOICE_FD before_len=${#before_buffer} before_buffer<<<$before_buffer>>> before_cursor=$before_cursor"
        IFS='|' read -r action text <&$VOICE_FD || {
            _egregore_debug "read failed fd=$VOICE_FD"
            return 1
        }
        _egregore_debug "message action=${action:-<empty>} text_len=${#text} text<<<$text>>>"
        EGREGORE_PENDING_ACTION="$action"
        EGREGORE_PENDING_TEXT="$text"
        zle _egregore_apply_pending
    }

    zle -N _egregore_apply_pending
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
