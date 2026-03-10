import SwiftUI

@main
struct EgregoreApp: App {
    @StateObject private var runtime = AppRuntime()

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra("Egregore", systemImage: "waveform.badge.mic") {
            MenuBarView(runtime: runtime)
        }
    }
}
