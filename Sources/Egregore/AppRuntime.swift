import AVFoundation
import ApplicationServices
import AppKit
import SwiftUI

@MainActor
final class AppRuntime: ObservableObject {
    enum MicrophoneStatus: String {
        case notDetermined = "Not requested"
        case authorized = "Granted"
        case denied = "Denied"
        case restricted = "Restricted"

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

    let shellSnippet = ShellIntegrationInstaller.snippet

    private let installer = ShellIntegrationInstaller()
    private let controller: SessionController
    private let hudController: HUDWindowController

    init() {
        let hotkeys = NSEventHotkeyManager()
        let pipeline = AVAudioEnginePipeline()
        let transcriber = WhisperKitTranscriber()
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
        self.hudController = HUDWindowController(hudStates: controller.hudStates)
        refreshStatus()
        hudController.show()
        Task { await controller.start() }
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

    func clearError() {
        lastError = nil
    }
}
