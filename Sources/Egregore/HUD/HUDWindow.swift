import AppKit
import Combine
import SwiftUI

@MainActor
final class HUDWindowController {
    nonisolated static let width: CGFloat = 420
    nonisolated static let height: CGFloat = 88
    nonisolated static let bottomMargin: CGFloat = 80

    private var window: NSWindow?
    private let viewModel: HUDViewModel
    private var screenObserver: Any?
    private var spaceObserver: Any?
    private var visibilitySub: AnyCancellable?

    init(hudStates: AsyncStream<HUDState>) {
        self.viewModel = HUDViewModel(hudStates: hudStates)
    }

    func show() {
        guard window == nil else { return }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.height),
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
        panel.setContentSize(CGSize(width: Self.width, height: Self.height))
        panel.contentMinSize = CGSize(width: Self.width, height: Self.height)
        panel.contentMaxSize = CGSize(width: Self.width, height: Self.height)

        layoutWindow(panel)
        panel.orderFront(nil)
        window = panel

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.relayout() } }

        spaceObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.relayout() } }

        visibilitySub = viewModel.$visible
            .receive(on: RunLoop.main)
            .sink { [weak self] visible in
                if visible { self?.relayout() }
            }
    }

    nonisolated static func anchoredFrame(screenFrame: CGRect, width: CGFloat = HUDWindowController.width, height: CGFloat = HUDWindowController.height, bottomMargin: CGFloat = HUDWindowController.bottomMargin) -> CGRect {
        let x = screenFrame.midX - width / 2
        let y = screenFrame.minY + bottomMargin
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func relayout() {
        guard let window else { return }
        layoutWindow(window)
    }

    private func layoutWindow(_ window: NSWindow) {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let frame = Self.anchoredFrame(screenFrame: screenFrame)
        window.setFrame(frame, display: true)
    }
}

@MainActor
final class HUDViewModel: ObservableObject {
    private static let finalStateDwell: UInt64 = 900_000_000

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
        case .listening, .recording, .transcribing:
            visible = true
        case .injected(_, let continueListening):
            visible = true
            fadeTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: Self.finalStateDwell)
                guard !Task.isCancelled else { return }
                self?.state = continueListening ? .listening : .idle
                self?.visible = continueListening
            }
        case .cleared(let continueListening):
            visible = true
            fadeTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: Self.finalStateDwell)
                guard !Task.isCancelled else { return }
                self?.state = continueListening ? .listening : .idle
                self?.visible = continueListening
            }
        case .error(_, let continueListening):
            visible = true
            fadeTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                guard !Task.isCancelled else { return }
                self?.state = continueListening ? .listening : .idle
                self?.visible = continueListening
            }
        }
    }
}

struct HUDContentView: View {
    @ObservedObject var viewModel: HUDViewModel

    var body: some View {
        Group {
            if viewModel.visible {
                hudBody
                    .fixedSize(horizontal: false, vertical: true)
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
        .frame(width: HUDWindowController.width, height: HUDWindowController.height, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.white.opacity(0.1), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch viewModel.state {
        case .listening:
            Circle()
                .fill(.red)
                .frame(width: 10, height: 10)
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
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var statusText: some View {
        switch viewModel.state {
        case .listening:
            Text("Listening")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.primary)
        case .recording(let partialText):
            VStack(alignment: .leading, spacing: 2) {
                Text("Listening")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(partialText)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
            }
        case .transcribing(let lastText):
            if let lastText, !lastText.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Finalizing")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(lastText)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                }
            } else {
                Text("Transcribing…")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        case .injected(let text, _):
            Text(text)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
        case .cleared:
            Text("Cleared")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
        case .error(let text, _):
            Text(text)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(2)
        default:
            EmptyView()
        }
    }
}
