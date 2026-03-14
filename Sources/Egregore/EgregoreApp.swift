import SwiftUI

@main
struct EgregoreApp: App {
    // MARK: Lifecycle

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    // MARK: Internal

    var body: some Scene {
        MenuBarExtra("Egregore", systemImage: "waveform.badge.mic") {
            MenuBarView(runtime: runtime)
        }
    }

    // MARK: Private

    @StateObject private var runtime = AppRuntime()
}
