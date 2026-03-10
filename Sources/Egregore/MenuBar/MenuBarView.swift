import SwiftUI

struct MenuBarView: View {
    @ObservedObject var runtime: AppRuntime

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            statusLine("Shell integration", runtime.shellIntegrationInstalled ? "Installed" : "Missing")
            statusLine("Microphone", runtime.microphoneStatus.rawValue)
            statusLine("Accessibility", runtime.accessibilityTrusted ? "Granted" : "Needs review")

            if let lastError = runtime.lastError {
                Text(lastError)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                Button("Dismiss Error") {
                    runtime.clearError()
                }
            }

            if !runtime.shellIntegrationInstalled {
                Text("Install the managed zsh snippet before expecting terminal injection to work.")
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
                Button("Install Shell Integration") {
                    runtime.installShellIntegration()
                }
            } else {
                Button("Uninstall Shell Integration") {
                    runtime.uninstallShellIntegration()
                }
            }

            if runtime.microphoneStatus == .notDetermined {
                Button("Request Microphone Access") {
                    runtime.requestMicrophoneAccess()
                }
            } else {
                Button("Refresh Permissions") {
                    runtime.refreshStatus()
                }
            }

            Button(runtime.showsShellSnippet ? "Hide Shell Snippet" : "Show Shell Snippet") {
                runtime.showsShellSnippet.toggle()
            }

            if runtime.showsShellSnippet {
                ScrollView {
                    Text(runtime.shellSnippet)
                        .font(.system(size: 10, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(width: 420, height: 180)
            }

            Divider()
            Text("Hold Right Command to record. Tap Right Control to toggle OPEN mode.")
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)

            Button("Open Log File") {
                NSWorkspace.shared.open(RuntimeLogger.logFileURL)
            }
            Text(RuntimeLogger.logFileURL.path(percentEncoded: false))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            Button("Quit Egregore") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(12)
        .frame(width: runtime.showsShellSnippet ? 460 : 320, alignment: .leading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Egregore")
                .font(.headline)
            Text("Session runtime active")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private func statusLine(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 11, design: .monospaced))
    }
}
