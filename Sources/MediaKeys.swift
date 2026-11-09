import AppKit
import ApplicationServices

/// Keyboard media keys (volume / brightness / mute). macOS delivers most of them as
/// NX_SYSDEFINED events (type 14, subtype 8 = NX_SUBTYPE_AUX_CONTROL_BUTTONS), but on
/// Apple keyboards attached to Apple Silicon Macs the brightness keys (F1/F2) arrive as
/// ordinary keyDown/keyUp events with key codes 144 (up) / 145 (down) - see MonitorControl's
/// MediaKeyTap `functionKeyCodeToMediaKey`. We handle both paths.
enum MediaKey: Int {
    case soundUp = 0          // NX_KEYTYPE_SOUND_UP
    case soundDown = 1        // NX_KEYTYPE_SOUND_DOWN
    case brightnessUp = 2     // NX_KEYTYPE_BRIGHTNESS_UP
    case brightnessDown = 3   // NX_KEYTYPE_BRIGHTNESS_DOWN
    case mute = 7             // NX_KEYTYPE_MUTE
}

/// Intercepts media keys with a CGEventTap (same approach as MonitorControl's MediaKeyTap).
/// Requires Accessibility permission. The tap is installed on the main run loop.
final class MediaKeyTap {
    /// Asked synchronously on the main thread: should this key go to the TV (and be swallowed)?
    var shouldIntercept: ((MediaKey) -> Bool)?
    /// Called on key-down (including auto-repeat) for intercepted keys.
    var onKey: ((MediaKey, NSEvent.ModifierFlags) -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    var isRunning: Bool { tap != nil }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system "allow Accessibility" prompt if the app isn't trusted yet.
    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// True when the tap also receives keyDown/keyUp (needed for brightness key codes 144/145).
    private(set) var capturesKeyEvents = false

    /// Installs the tap. Tries NX_SYSDEFINED + keyDown/keyUp first; if macOS refuses that,
    /// falls back to NX_SYSDEFINED only so the volume/mute keys keep working.
    @discardableResult
    func start() -> Bool {
        if tap != nil { return true }
        guard Self.isTrusted else { return false }
        let sysDefined = CGEventMask(1 << 14) // NX_SYSDEFINED
        let keyEvents = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
        if let t = makeTap(mask: sysDefined | keyEvents) {
            install(t)
            capturesKeyEvents = true
            return true
        }
        if let t = makeTap(mask: sysDefined) {
            install(t)
            capturesKeyEvents = false
            return true
        }
        return false
    }

    private func makeTap(mask: CGEventMask) -> CFMachPort? {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        return CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<MediaKeyTap>.fromOpaque(refcon).takeUnretainedValue()
                return me.handle(type: type, event: event)
            },
            userInfo: refcon
        )
    }

    private func install(_ tap: CFMachPort) {
        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        source = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        capturesKeyEvents = false
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        // Brightness keys sent as plain key events (key codes 144 / 145).
        if type == .keyDown || type == .keyUp {
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            let key: MediaKey
            switch code {
            case 144: key = .brightnessUp
            case 145: key = .brightnessDown
            default: return Unmanaged.passUnretained(event)
            }
            let intercept = MainActor.assumeIsolated { shouldIntercept?(key) ?? false }
            guard intercept else { return Unmanaged.passUnretained(event) }
            if type == .keyDown {
                let flags = NSEvent(cgEvent: event)?.modifierFlags ?? []
                MainActor.assumeIsolated { onKey?(key, flags) }
            }
            return nil
        }

        guard type.rawValue == 14,
              let ns = NSEvent(cgEvent: event),
              ns.subtype.rawValue == 8 else {
            return Unmanaged.passUnretained(event)
        }
        let data1 = ns.data1
        let keyCode = (data1 & 0xFFFF_0000) >> 16
        let keyFlags = data1 & 0x0000_FFFF
        let isDown = ((keyFlags & 0xFF00) >> 8) == 0xA

        guard let key = MediaKey(rawValue: keyCode) else { return Unmanaged.passUnretained(event) }

        let intercept = MainActor.assumeIsolated { shouldIntercept?(key) ?? false }
        guard intercept else { return Unmanaged.passUnretained(event) }

        if isDown {
            let flags = ns.modifierFlags
            MainActor.assumeIsolated { onKey?(key, flags) }
        }
        return nil // swallow both key-down and key-up so macOS doesn't also act on it
    }
}
