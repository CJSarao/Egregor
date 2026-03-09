import SwiftUI

struct MenuBarView: View {
    var body: some View {
        Text("VoiceShell")
            .padding(.vertical, 4)
        Divider()
        Button("Quit VoiceShell") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
