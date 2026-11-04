import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var tv: TVController

    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "tv") }
            KeyboardSettings()
                .tabItem { Label("Keyboard", systemImage: "keyboard") }
            AboutSettings()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 540, height: 560)
    }
}

// MARK: - General

struct GeneralSettings: View {
    @EnvironmentObject var tv: TVController

    private var autoDetectedName: String {
        let saved = tv.tvDisplayName
        guard saved.isEmpty else { return "" }
        return tv.tvScreen()?.localizedName ?? "none found"
    }

    var body: some View {
        Form {
            Section("TV") {
                TextField("IP address", text: $tv.host)
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle().fill(tv.isConnected ? Color.green : Color.secondary).frame(width: 7, height: 7)
                        Text(tv.status).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button(tv.isPaired ? "Reconnect" : "Pair") { Task { await tv.connect() } }
                        .glassButton(prominent: true)
                        .disabled(tv.isBusy || tv.host.isEmpty)
                    Button(tv.isDiscovering ? "Searching…" : "Find TVs") { Task { await tv.discover() } }
                        .glassButton()
                        .disabled(tv.isDiscovering)
                    Spacer()
                    if tv.isConnected {
                        Button("Disconnect") { tv.disconnect() }.glassButton()
                    }
                    if tv.isPaired {
                        Button("Forget Pairing", role: .destructive) { tv.forgetPairing() }.glassButton()
                    }
                }
                ForEach(tv.discovered) { found in
                    Button {
                        tv.host = found.ip
                        Task { await tv.connect() }
                    } label: {
                        LabeledContent(found.name, value: found.ip)
                    }
                    .buttonStyle(.borderless)
                }
            }

            Section {
                Picker("TV display", selection: $tv.tvDisplayName) {
                    Text("Auto-detect (\(autoDetectedName))").tag("")
                    ForEach(Array(Set(tv.screenNames)).sorted(), id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
            } header: {
                Text("Display")
            } footer: {
                Text("Used to decide when the keyboard's volume/brightness keys should control the TV, and where the on-screen indicator appears.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("App") {
                Toggle("Launch at login", isOn: Binding(
                    get: { tv.launchAtLogin },
                    set: { tv.setLaunchAtLogin($0) }
                ))
                Toggle("Show on-screen indicator (HUD)", isOn: $tv.showHUD)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Keyboard

struct KeyboardSettings: View {
    @EnvironmentObject var tv: TVController

    var body: some View {
        Form {
            Section {
                Picker("Volume & brightness keys control the TV", selection: $tv.mediaKeyMode) {
                    ForEach(MediaKeyMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                if tv.mediaKeyMode != .off {
                    if tv.accessibilityTrusted {
                        Label("Keyboard keys active", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        HStack(alignment: .top) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            Text("Needs Accessibility permission to read the volume and brightness keys. After granting it in System Settings, come back here.")
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button("Grant Access…") { tv.requestAccessibility() }
                                .glassButton(prominent: true)
                        }
                    }
                }
                Stepper("Volume step: \(tv.volumeStep)", value: $tv.volumeStep, in: 1...10)
                Stepper("Brightness step: \(tv.brightnessStepSize)", value: $tv.brightnessStepSize, in: 1...20)
            } header: {
                Text("Keyboard media keys")
            } footer: {
                Text("Like BetterDisplay: when the pointer is on the TV, 🔊/🔉/🔇 and ☀︎ keys change the TV instead of the Mac. Hold ⌥⇧ while pressing a key for steps of 1.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                ForEach(TVAction.allCases) { action in
                    HStack {
                        Label(action.title, systemImage: action.symbol)
                        Spacer()
                        ShortcutRecorder(action: action)
                    }
                }
                HStack {
                    Spacer()
                    Button("Restore Defaults") { tv.resetShortcuts() }.glassButton()
                }
            } header: {
                Text("Custom shortcuts")
            } footer: {
                Text("Click a shortcut, then press the new key combination. Esc cancels, ⌫ clears. Shortcuts work in any app.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - About

struct AboutSettings: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "tv.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 76, height: 76)
                .glassCircle(tint: Color.accentColor.opacity(0.2))
            Text("OLEDial").font(.system(.title2, design: .rounded).weight(.bold))
            Text("Version \(AppInfo.version) (\(AppInfo.build))").foregroundStyle(.secondary)
            Text("Controls LG webOS TVs over your local network.\nProtocol details based on the open-source aiowebostv and bscpylgtv projects.")
                .multilineTextAlignment(.center)
                .font(.callout)
                .foregroundStyle(.secondary)
            if let url = AppInfo.repoURL {
                Link("Source on GitHub", destination: url)
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
