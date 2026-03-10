import AppKit
import SwiftUI

@MainActor
final class HUDWindowController {
    private var window: NSWindow?
    private let viewModel: HUDViewModel

    init(hudStates: AsyncStream<HUDState>) {
        self.viewModel = HUDViewModel(hudStates: hudStates)
    }

    func show() {
        guard window == nil else { return }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 64),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView: HUDContentView(viewModel: viewModel))

        positionAtBottomCenter(panel)
        panel.orderFront(nil)
        window = panel
    }

    private func positionAtBottomCenter(_ window: NSWindow) {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - window.frame.width / 2
        let y = screenFrame.minY + 80
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

@MainActor
final class HUDViewModel: ObservableObject {
    @Published var state: HUDState = .idle
    @Published var visible = false

    private var fadeTask: Task<Void, Never>?

    init(hudStates: AsyncStream<HUDState>) {
        Task { @MainActor [weak self] in
            for await newState in hudStates {
                self?.apply(newState)
            }
        }
    }

    private func apply(_ newState: HUDState) {
        fadeTask?.cancel()
        state = newState

        switch newState {
        case .idle:
            visible = false
        case .recording, .transcribing:
            visible = true
        case .injected:
            visible = true
            fadeTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                guard !Task.isCancelled else { return }
                self?.visible = false
                self?.state = .idle
            }
        case .cleared:
            visible = false
            state = .idle
        }
    }
}

struct HUDContentView: View {
    @ObservedObject var viewModel: HUDViewModel

    var body: some View {
        Group {
            if viewModel.visible {
                hudBody
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.visible)
    }

    @ViewBuilder
    private var hudBody: some View {
        HStack(spacing: 10) {
            statusIcon
            statusText
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.white.opacity(0.1), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch viewModel.state {
        case .recording:
            Circle()
                .fill(.red)
                .frame(width: 10, height: 10)
        case .transcribing:
            ProgressView()
                .controlSize(.small)
        case .injected:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var statusText: some View {
        switch viewModel.state {
        case .recording(let mode):
            Text(mode == .ptt ? "Listening (PTT)" : "Listening (Open)")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.primary)
        case .transcribing:
            Text("Transcribing…")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
        case .injected(let text):
            Text(text)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
        default:
            EmptyView()
        }
    }
}
