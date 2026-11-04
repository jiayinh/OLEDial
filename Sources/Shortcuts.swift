import AppKit
import Carbon
import SwiftUI

/// Actions that can be bound to a custom global shortcut.
enum TVAction: String, CaseIterable, Codable, Identifiable {
    case volumeUp, volumeDown, mute, brightnessUp, brightnessDown, powerOff

    var id: String { rawValue }

    var title: String {
        switch self {
        case .volumeUp: return "Volume Up"
        case .volumeDown: return "Volume Down"
        case .mute: return "Mute / Unmute"
        case .brightnessUp: return "Brightness Up"
        case .brightnessDown: return "Brightness Down"
        case .powerOff: return "Turn TV Off"
        }
    }

    var symbol: String {
        switch self {
        case .volumeUp: return "speaker.wave.3.fill"
        case .volumeDown: return "speaker.wave.1.fill"
        case .mute: return "speaker.slash.fill"
        case .brightnessUp: return "sun.max.fill"
        case .brightnessDown: return "sun.min.fill"
        case .powerOff: return "power"
        }
    }
}

/// A key + Carbon modifier mask, e.g. ⌃⌥⇧↑.
struct KeyCombo: Codable, Equatable {
    var keyCode: Int
    var modifiers: Int   // Carbon: cmdKey | optionKey | controlKey | shiftKey
    var keyName: String

    var display: String {
        var s = ""
        if modifiers & controlKey != 0 { s += "⌃" }
        if modifiers & optionKey != 0 { s += "⌥" }
        if modifiers & shiftKey != 0 { s += "⇧" }
        if modifiers & cmdKey != 0 { s += "⌘" }
        return s + keyName
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> Int {
        var m = 0
        if flags.contains(.command) { m |= cmdKey }
        if flags.contains(.option) { m |= optionKey }
        if flags.contains(.control) { m |= controlKey }
        if flags.contains(.shift) { m |= shiftKey }
        return m
    }

    static let specialKeyNames: [Int: String] = [
        kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦", kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
        kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]

    static let functionKeyCodes: Set<Int> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]

    static func name(for event: NSEvent) -> String {
        let code = Int(event.keyCode)
        if let special = specialKeyNames[code] { return special }
        let base = event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers ?? "?"
        return base.uppercased()
    }

    static let defaults: [TVAction: KeyCombo] = {
        let mods = controlKey | optionKey | shiftKey
        return [
            .volumeUp: KeyCombo(keyCode: kVK_UpArrow, modifiers: mods, keyName: "↑"),
            .volumeDown: KeyCombo(keyCode: kVK_DownArrow, modifiers: mods, keyName: "↓"),
            .brightnessUp: KeyCombo(keyCode: kVK_RightArrow, modifiers: mods, keyName: "→"),
            .brightnessDown: KeyCombo(keyCode: kVK_LeftArrow, modifiers: mods, keyName: "←"),
            .mute: KeyCombo(keyCode: kVK_ANSI_M, modifiers: mods, keyName: "M"),
        ]
    }()
}

/// Click, then press a key combination. Esc cancels, ⌫ (without modifiers) clears.
struct ShortcutRecorder: View {
    let action: TVAction
    @EnvironmentObject var tv: TVController
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button {
                recording ? stop() : start()
            } label: {
                Text(recording ? "Type shortcut…" : (tv.shortcuts[action]?.display ?? "Record Shortcut"))
                    .font(.system(.body, design: .rounded).monospaced())
                    .foregroundStyle(recording ? Color.accentColor : (tv.shortcuts[action] == nil ? .secondary : .primary))
                    .frame(minWidth: 130)
            }
            .glassButton()

            if tv.shortcuts[action] != nil, !recording {
                Button {
                    tv.setShortcut(nil, for: action)
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Remove shortcut")
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        tv.suspendHotkeys(true)
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let code = Int(event.keyCode)
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let mods = KeyCombo.carbonModifiers(from: flags)
            if code == kVK_Escape { stop(); return nil }
            if code == kVK_Delete, mods == 0 { tv.setShortcut(nil, for: action); stop(); return nil }
            guard mods != 0 || KeyCombo.functionKeyCodes.contains(code) else {
                NSSound.beep()   // require a modifier, except for F-keys
                return nil
            }
            tv.setShortcut(KeyCombo(keyCode: code, modifiers: mods, keyName: KeyCombo.name(for: event)),
                           for: action)
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording { tv.suspendHotkeys(false) }
        recording = false
    }
}
