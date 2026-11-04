import AppKit
import SwiftUI

/// On-screen indicator shown when volume/brightness change via keys (like the system HUD / BetterDisplay).
@MainActor
final class HUDModel: ObservableObject {
    @Published var symbol = "speaker.wave.2.fill"
    @Published var title = "Volume"
    @Published var value: Double = 0      // 0...100
    @Published var muted = false
}

struct HUDView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: model.symbol)
                .font(.system(size: 22, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .frame(width: 30)
                .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(model.title).font(.system(.subheadline, design: .rounded).weight(.semibold))
                    Spacer()
                    Text(model.muted ? "Muted" : "\(Int(model.value))")
                        .font(.system(.subheadline, design: .rounded).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.15))
                        Capsule()
                            .fill(Color.primary.opacity(model.muted ? 0.3 : 0.85))
                            .frame(width: max(6, geo.size.width * CGFloat(model.value / 100)))
                    }
                }
                .frame(height: 6)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .frame(width: 300, height: 72)
        .glassCapsule()
        .animation(.snappy(duration: 0.18), value: model.value)
        .animation(.snappy(duration: 0.18), value: model.muted)
        .padding(10) // room for the glass shadow
    }
}

@MainActor
final class HUDController {
    static let shared = HUDController()

    private let model = HUDModel()
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func show(symbol: String, title: String, value: Double, muted: Bool = false, on screen: NSScreen?) {
        model.symbol = symbol
        model.title = title
        model.value = min(100, max(0, value))
        model.muted = muted

        let panel = self.panel ?? makePanel()
        self.panel = panel

        if let screen = screen ?? NSScreen.main {
            let size = panel.frame.size
            let vf = screen.visibleFrame
            let origin = NSPoint(x: vf.midX - size.width / 2, y: vf.minY + vf.height * 0.12)
            panel.setFrameOrigin(origin)
        }
        if !panel.isVisible { panel.alphaValue = 0 }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1
        }, completionHandler: nil)

        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            guard !Task.isCancelled, let self, let panel = self.panel else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.35
                panel.animator().alphaValue = 0
            }, completionHandler: nil)
            try? await Task.sleep(nanoseconds: 400_000_000)
            if !Task.isCancelled { panel.orderOut(nil) }
        }
    }

    private func makePanel() -> NSPanel {
        let host = NSHostingView(rootView: HUDView(model: model))
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 92)
        let panel = NSPanel(contentRect: host.frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.contentView = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        return panel
    }
}
