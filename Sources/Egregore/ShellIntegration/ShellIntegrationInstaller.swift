import Foundation

struct ShellIntegrationInstaller {
    private static let beginMarker = "# BEGIN Egregore integration — managed by Egregore.app"
    private static let endMarker = "# END Egregore integration"

    // Swift multiline raw string: closing """# at 4-space indent strips 4 spaces from each content line
    static let snippet: String = #"""
    # BEGIN Egregore integration — managed by Egregore.app
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

    _egregore_json_escape() {
        local value="$1"
        value="${value//\\/\\\\}"
        value="${value//\"/\\\"}"
        value="${value//$'\n'/\\n}"
        print -r -- "$value"
    }

    _egregore_write_session_state() {
        mkdir -p "$VOICE_REGISTRY"
        local tty_value
        tty_value="$(tty 2>/dev/null || print -r -- "")"
        tty_value="${tty_value//$'\n'/}"
        print -r -- "{\"pipePath\":\"$(_egregore_json_escape "$VOICE_PIPE")\",\"lastPromptAt\":${EGREGORE_LAST_PROMPT_AT:-0},\"lastFocusAt\":${EGREGORE_LAST_FOCUS_AT:-0},\"isFocused\":${EGREGORE_IS_FOCUSED:-false},\"isAtPrompt\":${EGREGORE_IS_AT_PROMPT:-false},\"tty\":\"$(_egregore_json_escape "$tty_value")\"}" > "$VOICE_REGISTRY/$$"
    }

    _egregore_mark_prompt_ready() {
        _egregore_mark_active
        EGREGORE_LAST_PROMPT_AT="${EPOCHREALTIME:-0}"
        EGREGORE_LAST_FOCUS_AT="${EPOCHREALTIME:-0}"
        EGREGORE_IS_FOCUSED=true
        EGREGORE_IS_AT_PROMPT=true
        _egregore_write_session_state
    }

    _egregore_mark_busy() {
        _egregore_mark_active
        EGREGORE_IS_FOCUSED=false
        EGREGORE_IS_AT_PROMPT=false
        _egregore_write_session_state
    }

    mkfifo "$VOICE_PIPE" 2>/dev/null
    exec {VOICE_FD}<>"$VOICE_PIPE"
    mkdir -p "$VOICE_REGISTRY"
    typeset -g EGREGORE_LAST_PROMPT_AT="${EPOCHREALTIME:-0}"
    typeset -g EGREGORE_LAST_FOCUS_AT="${EPOCHREALTIME:-0}"
    typeset -g EGREGORE_IS_FOCUSED=true
    typeset -g EGREGORE_IS_AT_PROMPT=true
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
                _egregore_debug "send applied buffer_len=${#BUFFER} buffer<<<$BUFFER>>> cursor=$CURSOR"
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
    # END Egregore integration
    """#

    let zshrcURL: URL
    let registryURL: URL
    let activityURL: URL
    let egregoreConfigURL: URL

    init(
        zshrcURL: URL = URL.homeDirectory.appending(path: ".zshrc"),
        registryURL: URL = URL.homeDirectory.appending(path: ".config/egregore/sessions"),
        activityURL: URL = URL.homeDirectory.appending(path: ".config/egregore/activity"),
        egregoreConfigURL: URL = URL.homeDirectory.appending(path: ".config/egregore")
    ) {
        self.zshrcURL = zshrcURL
        self.registryURL = registryURL
        self.activityURL = activityURL
        self.egregoreConfigURL = egregoreConfigURL
    }

    var isInstalled: Bool {
        guard let content = try? String(contentsOf: zshrcURL, encoding: .utf8) else { return false }
        return content.contains(Self.beginMarker)
    }

    func install() throws {
        let fm = FileManager.default
        try FileManager.default.createDirectory(at: registryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: activityURL, withIntermediateDirectories: true)
        if fm.fileExists(atPath: zshrcURL.path) {
            let content = try String(contentsOf: zshrcURL, encoding: .utf8)
            let preserved = content.contains(Self.beginMarker) ? removeBlock(from: content) : content
            let trimmed = preserved.trimmingCharacters(in: .newlines)
            let updated = trimmed.isEmpty
                ? Self.snippet + "\n"
                : trimmed + "\n\n" + Self.snippet + "\n"
            try updated.write(to: zshrcURL, atomically: true, encoding: .utf8)
        } else {
            try (Self.snippet + "\n").write(to: zshrcURL, atomically: true, encoding: .utf8)
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
