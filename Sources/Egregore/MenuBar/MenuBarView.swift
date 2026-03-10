import SwiftUI

struct MenuBarView: View {
    var body: some View {
        Text("Egregore")
            .padding(.vertical, 4)
        Divider()
        Button("Quit Egregore") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
