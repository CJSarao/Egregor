import SwiftUI

struct MenuBarView: View {
    @ObservedObject var runtime: AppRuntime

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()

            if runtime.showsSetup {
                setupSection
                Divider()
            }

            statusLine("Shell integration", runtime.shellIntegrationInstalled ? "Installed" : "Missing")
            statusLine("Microphone", runtime.microphoneStatus.rawValue)
            statusLine("Accessibility", runtime.accessibilityTrusted ? "Granted" : "Not Granted — required for ROGER")

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
                Button("Reinstall Shell Integration") {
                    runtime.installShellIntegration()
                }
                Button("Uninstall Shell Integration") {
                    runtime.uninstallShellIntegration()
                }
            }

            if !runtime.accessibilityTrusted {
                Button("Open Accessibility Settings") {
                    runtime.openAccessibilitySettings()
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
            hotkeyBindingsSection

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

    private var setupSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Setup")
                .font(.system(size: 12, weight: .semibold))

            setupStep(
                number: 1,
                title: "Microphone",
                status: runtime.microphoneStatus == .authorized ? "Granted" : runtime.microphoneStatus.rawValue,
                done: runtime.microphoneStatus == .authorized
            ) {
                if runtime.microphoneStatus == .notDetermined {
                    Button("Request Access") { runtime.requestMicrophoneAccess() }
                }
            }

            setupStep(
                number: 2,
                title: "Accessibility",
                status: runtime.accessibilityTrusted ? "Granted" : "Required",
                done: runtime.accessibilityTrusted
            ) {
                if !runtime.accessibilityTrusted {
                    Button("Open System Settings") { runtime.openAccessibilitySettings() }
                }
            }

            setupStep(
                number: 3,
                title: "Shell Integration",
                status: runtime.shellIntegrationInstalled ? "Installed" : "Not installed",
                done: runtime.shellIntegrationInstalled
            ) {
                if !runtime.shellIntegrationInstalled {
                    Button("Install") { runtime.installShellIntegration() }
                }
            }

            setupStep(
                number: 4,
                title: "Open a new terminal tab",
                status: "Existing shells won't pick up changes",
                done: false
            ) { EmptyView() }

            HStack {
                if !runtime.needsSetup {
                    Button("Done") { runtime.completeSetup() }
                        .buttonStyle(.borderedProminent)
                }
                Button("Refresh") { runtime.refreshStatus() }
            }
        }
    }

    @ViewBuilder
    private func setupStep<Content: View>(number: Int, title: String, status: String, done: Bool, @ViewBuilder action: () -> Content) -> some View {
        HStack(spacing: 6) {
            Text(done ? "\u{2713}" : "\(number)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(done ? .green : .secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                Text(status)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            action()
        }
    }

    private var hotkeyBindingsSection: some View {
        let b = runtime.hotkeyBindings
        return VStack(alignment: .leading, spacing: 4) {
            Text("Hotkeys")
                .font(.system(size: 11, weight: .semibold))
            statusLine("Toggle mic", "Tap \(b.toggleKey.displayName)")

            Toggle("Key diagnostics", isOn: Binding(
                get: { runtime.keyDiagnosticsEnabled },
                set: { runtime.setKeyDiagnostics($0) }
            ))
            .font(.system(size: 11))

            if runtime.keyDiagnosticsEnabled {
                Text("All key events logged — check log file")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }
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
