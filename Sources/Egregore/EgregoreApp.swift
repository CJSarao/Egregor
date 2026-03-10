import SwiftUI

@main
struct EgregoreApp: App {
    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra("Egregore", systemImage: "waveform.badge.mic") {
            MenuBarView()
        }
    }
}
