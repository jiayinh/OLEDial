import Foundation
import IOKit.hid

/// Watches the volume/mute buttons of HID "consumer control" devices (USB speakerphones,
/// headsets, docks such as Microsoft Audio Dock) so OLEDial can tell which device a volume
/// key press came from. macOS's media-key events don't carry that information.
/// Requires the Input Monitoring permission.
final class HIDVolumeWatcher {
    struct Press {
        let deviceName: String
        let usage: UInt32       // 0xE9 volume up, 0xEA volume down, 0xE2 mute
        let time: CFAbsoluteTime
        var held: Bool
        var consumed = false
    }

    /// Called on the main thread for every button press (for diagnostics in Settings).
    var onPress: ((Press) -> Void)?
    private(set) var lastPress: Press?
    private var manager: IOHIDManager?

    var isRunning: Bool { manager != nil }

    static var accessGranted: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    /// Shows the system Input Monitoring prompt (first time only).
    @discardableResult
    static func requestAccess() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    @discardableResult
    func start() -> Bool {
        if manager != nil { return true }
        guard Self.accessGranted else { return false }
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDDeviceUsagePageKey as String: kHIDPage_Consumer,
            kIOHIDDeviceUsageKey as String: kHIDUsage_Csmr_ConsumerControl,
        ]
        IOHIDManagerSetDeviceMatching(m, matching as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(m, { context, _, _, value in
            guard let context else { return }
            Unmanaged<HIDVolumeWatcher>.fromOpaque(context).takeUnretainedValue().handle(value)
        }, context)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        guard IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            return false
        }
        manager = m
        return true
    }

    func stop() {
        guard let m = manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(m, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = nil
    }

    /// The press that explains a volume key event arriving now: the button is still held,
    /// or it was pressed within the last 300 ms and hasn't been used yet.
    func takeRecentPress() -> Press? {
        guard var p = lastPress else { return nil }
        if p.held { return p }
        guard !p.consumed, CFAbsoluteTimeGetCurrent() - p.time < 0.3 else { return nil }
        p.consumed = true
        lastPress = p
        return p
    }

    private func handle(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let page = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        guard page == UInt32(kHIDPage_Consumer), usage == 0xE9 || usage == 0xEA || usage == 0xE2 else { return }
        let pressed = IOHIDValueGetIntegerValue(value) != 0
        if !pressed {
            if lastPress?.usage == usage { lastPress?.held = false }
            return
        }
        let device = IOHIDElementGetDevice(element)
        let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "Unknown device"
        let press = Press(deviceName: name, usage: usage, time: CFAbsoluteTimeGetCurrent(), held: true)
        lastPress = press
        onPress?(press)
    }
}
