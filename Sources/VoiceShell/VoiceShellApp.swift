import SwiftUI

@main
struct VoiceShellApp: App {
    init() {
        NSApp.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra("VoiceShell", systemImage: "waveform.badge.mic") {
            MenuBarView()
        }
    }
}
