import AppKit
import SwiftUI

struct MenuView: View {
    @EnvironmentObject var tv: TVController

    var body: some View {
        VStack(spacing: 12) {
            header
            if tv.isConnected {
                controls
            } else {
                connectCard
            }
            if let err = tv.lastError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            footer
        }
        .padding(14)
        .frame(width: 330)
    }

    // MARK: Header

    private var statusColor: Color {
        tv.isConnected ? .green : (tv.isBusy ? .orange : .secondary)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: tv.isConnected ? "tv.fill" : "tv")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tv.isConnected ? Color.accentColor : Color.secondary)
                .frame(width: 38, height: 38)
                .glassCircle(tint: tv.isConnected ? Color.accentColor.opacity(0.25) : nil)

            VStack(alignment: .leading, spacing: 2) {
                Text("LG TV").font(.system(.headline, design: .rounded))
                HStack(spacing: 5) {
                    Circle().fill(statusColor).frame(width: 6, height: 6)
                    Text(tv.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if tv.isConnected {
                Button { tv.powerOff() } label: {
                    Image(systemName: "power")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 18, height: 18)
                }
                .glassButton()
                .help("Turn TV off")
            }
        }
    }

    // MARK: Controls

    private var volumeSymbol: String {
        if tv.muted || tv.volume == 0 { return "speaker.slash.fill" }
        if tv.volume < 34 { return "speaker.wave.1.fill" }
        if tv.volume < 67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    private var controls: some View {
        GlassGroup(spacing: 10) {
            VStack(spacing: 10) {
                ControlCard(
                    title: "Volume",
                    symbol: volumeSymbol,
                    tint: .blue,
                    valueText: tv.muted ? "Muted" : "\(Int(tv.volume))",
                    value: Binding(get: { tv.volume }, set: { tv.setVolume($0) }),
                    editing: { tv.volumeEditing = $0 },
                    onMinus: { tv.adjustVolume(by: -tv.volumeStep) },
                    onPlus: { tv.adjustVolume(by: tv.volumeStep) },
                    symbolAction: { tv.toggleMute() },
                    symbolHelp: tv.muted ? "Unmute" : "Mute"
                )
                if tv.brightnessAvailable {
                    ControlCard(
                        title: "Brightness",
                        symbol: tv.brightness < 50 ? "sun.min.fill" : "sun.max.fill",
                        tint: .orange,
                        valueText: "\(Int(tv.brightness))",
                        value: Binding(get: { tv.brightness }, set: { tv.setBrightness($0) }),
                        editing: { tv.brightnessEditing = $0 },
                        onMinus: { tv.adjustBrightness(by: -tv.brightnessStepSize) },
                        onPlus: { tv.adjustBrightness(by: tv.brightnessStepSize) },
                        symbolAction: nil,
                        symbolHelp: "OLED Pixel Brightness"
                    )
                } else {
                    Label("Brightness isn't reported in this picture mode.", systemImage: "sun.max.trianglebadge.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .glassCard()
                }
            }
        }
    }

    // MARK: Connect

    private var connectCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Connect your LG TV").font(.system(.subheadline, design: .rounded).weight(.semibold))
            HStack(spacing: 8) {
                TextField("TV IP address, e.g. 192.168.1.50", text: $tv.host)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await tv.connect() } }
                Button(tv.isPaired ? "Connect" : "Pair") { Task { await tv.connect() } }
                    .glassButton(prominent: true)
                    .disabled(tv.isBusy || tv.host.isEmpty)
            }
            HStack {
                Button {
                    Task { await tv.discover() }
                } label: {
                    Label(tv.isDiscovering ? "Searching…" : "Find TVs on network", systemImage: "dot.radiowaves.left.and.right")
                }
                .glassButton()
                .disabled(tv.isDiscovering)
                Spacer()
                if tv.isBusy || tv.isDiscovering { ProgressView().controlSize(.small) }
            }
            ForEach(tv.discovered) { found in
                Button {
                    tv.host = found.ip
                    Task { await tv.connect() }
                } label: {
                    HStack {
                        Image(systemName: "tv")
                        Text(found.name).lineLimit(1)
                        Spacer()
                        Text(found.ip).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
            }
            Text("Tip: enable “TV On With Mobile” on the TV (Settings › General › Devices › External Devices) so it can be reached while in standby.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .glassCard()
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button {
                SettingsWindowController.shared.show(tv: tv)
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .glassButton()
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .glassButton()
                .keyboardShortcut("q")
        }
    }
}

/// A glass card with icon, title, big value, and a slider with −/+ buttons.
struct ControlCard: View {
    let title: String
    let symbol: String
    let tint: Color
    let valueText: String
    let value: Binding<Double>
    let editing: (Bool) -> Void
    let onMinus: () -> Void
    let onPlus: () -> Void
    let symbolAction: (() -> Void)?
    let symbolHelp: String

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                icon
                Text(title).font(.system(.subheadline, design: .rounded).weight(.semibold))
                Spacer()
                Text(valueText)
                    .font(.system(.title3, design: .rounded).weight(.semibold).monospacedDigit())
                    .contentTransition(.numericText())
                    .animation(.snappy, value: valueText)
            }
            HStack(spacing: 8) {
                Button(action: onMinus) { Image(systemName: "minus").frame(width: 16, height: 16) }
                    .buttonStyle(.borderless)
                Slider(value: value, in: 0...100, onEditingChanged: editing)
                    .tint(tint)
                    .controlSize(.small)
                Button(action: onPlus) { Image(systemName: "plus").frame(width: 16, height: 16) }
                    .buttonStyle(.borderless)
            }
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .glassCard()
    }

    @ViewBuilder
    private var icon: some View {
        let image = Image(systemName: symbol)
            .font(.system(size: 14, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(tint)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 30, height: 30)
            .glassCircle(tint: tint.opacity(0.18))
        if let symbolAction {
            Button(action: symbolAction) { image }
                .buttonStyle(.plain)
                .help(symbolHelp)
        } else {
            image.help(symbolHelp)
        }
    }
}
