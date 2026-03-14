import AVFoundation
import ApplicationServices
import AppKit
import SwiftUI

@MainActor
final class AppRuntime: ObservableObject {
    // MARK: Lifecycle

    init() {
        let bindings = HotkeyBindings.default
        hotkeyBindings = bindings
        let hotkeys = NSEventHotkeyManager(bindings: bindings)
        hotkeyManager = hotkeys
        let pipeline = AVAudioEnginePipeline()
        let transcriber = WhisperKitTranscriber()
        self.transcriber = transcriber
        let resolver = EgregoreIntentResolver()
        let output = ShellOutputManager()
        let controller = SessionController(
            hotkeys: hotkeys,
            pipeline: pipeline,
            transcriber: transcriber,
            resolver: resolver,
            output: output
        )

        self.controller = controller
        hudController = HUDWindowController(hudStates: controller.hudStates)
        refreshStatus()
        if !UserDefaults.standard.bool(forKey: Self.hasCompletedSetupKey) || needsSetup {
            showsSetup = true
        }
        if !accessibilityTrusted {
            startAccessibilityPolling()
        }
        hudController.show()
        RuntimeLogger.shared
            .log("Egregore started — mic: \(microphoneStatus.rawValue), accessibility: \(accessibilityTrusted), shell: \(shellIntegrationInstalled)")
        Task { await transcriber.prepare() }
        Task { await controller.start() }
    }

    // MARK: Internal

    enum MicrophoneStatus: String {
        case notDetermined = "Not requested"
        case authorized = "Granted"
        case denied = "Denied"
        case restricted = "Restricted"

        // MARK: Lifecycle

        init(_ status: AVAuthorizationStatus) {
            switch status {
            case .authorized:
                self = .authorized
            case .denied:
                self = .denied
            case .restricted:
                self = .restricted
            case .notDetermined:
                self = .notDetermined
            @unknown default:
                self = .restricted
            }
        }
    }

    @Published private(set) var shellIntegrationInstalled = false
    @Published private(set) var microphoneStatus = MicrophoneStatus(AVCaptureDevice.authorizationStatus(for: .audio))
    @Published private(set) var accessibilityTrusted = AXIsProcessTrusted()
    @Published private(set) var lastError: String?
    @Published var showsShellSnippet = false
    @Published private(set) var keyDiagnosticsEnabled = false
    @Published var showsSetup = false

    let shellSnippet = ShellIntegrationInstaller.snippet
    let hotkeyBindings: HotkeyBindings

    var needsSetup: Bool {
        !shellIntegrationInstalled || microphoneStatus != .authorized || !accessibilityTrusted
    }

    func refreshStatus() {
        shellIntegrationInstalled = installer.isInstalled
        microphoneStatus = MicrophoneStatus(AVCaptureDevice.authorizationStatus(for: .audio))
        accessibilityTrusted = AXIsProcessTrusted()
    }

    func requestMicrophoneAccess() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Task { @MainActor in
                self.microphoneStatus = granted ? .authorized : .denied
            }
        }
    }

    func installShellIntegration() {
        do {
            try installer.install()
            lastError = nil
            refreshStatus()
        } catch {
            lastError = "Shell integration install failed: \(error.localizedDescription)"
        }
    }

    func uninstallShellIntegration() {
        do {
            try installer.uninstall()
            lastError = nil
            refreshStatus()
        } catch {
            lastError = "Shell integration uninstall failed: \(error.localizedDescription)"
        }
    }

    func completeSetup() {
        UserDefaults.standard.set(true, forKey: Self.hasCompletedSetupKey)
        showsSetup = false
    }

    func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func clearError() {
        lastError = nil
    }

    func setKeyDiagnostics(_ enabled: Bool) {
        keyDiagnosticsEnabled = enabled
        Task { await hotkeyManager.setDiagnostics(enabled: enabled) }
    }

    // MARK: Private

    private static let hasCompletedSetupKey = "egregore.hasCompletedSetup"

    private let installer = ShellIntegrationInstaller()
    private let controller: SessionController
    private let hudController: HUDWindowController
    private let hotkeyManager: NSEventHotkeyManager
    private let transcriber: WhisperKitTranscriber
    private var accessibilityTimer: Timer?

    private func startAccessibilityPolling() {
        accessibilityTimer?.invalidate()
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else {
                    timer.invalidate()
                    return
                }
                self.accessibilityTrusted = AXIsProcessTrusted()
                if self.accessibilityTrusted {
                    timer.invalidate()
                    self.accessibilityTimer = nil
                }
            }
        }
    }
}
