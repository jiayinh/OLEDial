import CoreAudio
import Foundation

/// Reads the Mac's current default sound output device via Core Audio.
/// Used to decide whether the volume keys should go to the TV or stay with the Mac.
enum AudioOutput {
    struct Device {
        let id: AudioDeviceID
        let name: String
        let transport: UInt32
        let canSetVolume: Bool

        /// HDMI / DisplayPort output = sound is going to a display (likely the TV).
        var isDisplayAudio: Bool {
            transport == UInt32(kAudioDeviceTransportTypeHDMI) || transport == UInt32(kAudioDeviceTransportTypeDisplayPort)
        }
    }

    static func current() -> Device? {
        guard let id = defaultOutputID() else { return nil }
        return Device(id: id, name: name(of: id) ?? "Unknown output",
                      transport: transport(of: id), canSetVolume: canSetVolume(id))
    }

    /// All devices that can play sound.
    static func outputDevices() -> [Device] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter(hasOutput).map {
            Device(id: $0, name: name(of: $0) ?? "Unknown output",
                   transport: transport(of: $0), canSetVolume: canSetVolume($0))
        }
    }

    /// The output device that belongs to a HID device (e.g. the speaker inside a dock whose
    /// buttons were pressed), matched by name. Display audio (HDMI/DisplayPort) is excluded.
    static func speaker(matchingHIDName hidName: String) -> Device? {
        let hid = normalize(hidName)
        guard !hid.isEmpty else { return nil }
        let candidates = outputDevices().filter { !$0.isDisplayAudio && $0.canSetVolume }
        if let exact = candidates.first(where: { normalize($0.name) == hid }) { return exact }
        if let partial = candidates.first(where: {
            let n = normalize($0.name)
            return n.count >= 4 && (n.contains(hid) || hid.contains(n))
        }) { return partial }
        let hidWords = Set(hid.split(separator: " ").filter { $0.count >= 3 })
        return candidates.first(where: {
            let words = Set(normalize($0.name).split(separator: " ").filter { $0.count >= 3 })
            return words.intersection(hidWords).count >= 2
        })
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "(r)", with: "")
            .replacingOccurrences(of: "\u{00AE}", with: "")
            .replacingOccurrences(of: "\u{2122}", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: Volume / mute

    private static func volumeAddress(_ element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                   mScope: kAudioDevicePropertyScopeOutput, mElement: element)
    }

    /// Elements to read/write: the main element if it has a volume, otherwise channels 1 and 2.
    private static func volumeElements(_ id: AudioDeviceID) -> [AudioObjectPropertyElement] {
        var main = volumeAddress(kAudioObjectPropertyElementMain)
        if AudioObjectHasProperty(id, &main) { return [kAudioObjectPropertyElementMain] }
        let channels: [AudioObjectPropertyElement] = [1, 2]
        return channels.filter { element in
            var addr = volumeAddress(element)
            return AudioObjectHasProperty(id, &addr)
        }
    }

    /// 0...1
    static func volume(of id: AudioDeviceID) -> Float? {
        guard let element = volumeElements(id).first else { return nil }
        var addr = volumeAddress(element)
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    static func setVolume(_ volume: Float, of id: AudioDeviceID) {
        var value = Float32(min(1, max(0, volume)))
        for element in volumeElements(id) {
            var addr = volumeAddress(element)
            _ = AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
        }
    }

    private static func muteAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                   mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    static func isMuted(_ id: AudioDeviceID) -> Bool {
        var addr = muteAddress()
        guard AudioObjectHasProperty(id, &addr) else { return false }
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr && value != 0
    }

    /// Returns false if the device has no mute control.
    @discardableResult
    static func setMuted(_ muted: Bool, of id: AudioDeviceID) -> Bool {
        var addr = muteAddress()
        guard AudioObjectHasProperty(id, &addr) else { return false }
        var value = UInt32(muted ? 1 : 0)
        return AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    private static func hasOutput(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }

    private static func defaultOutputID() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return status == noErr && id != 0 ? id : nil
    }

    private static func name(of id: AudioDeviceID) -> String? {
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name) == noErr,
              let value = name?.takeRetainedValue() else { return nil }
        return value as String
    }

    private static func transport(of id: AudioDeviceID) -> UInt32 {
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        _ = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value)
        return value
    }

    /// True if macOS can change this device's volume (main element or channel 1/2).
    private static func canSetVolume(_ id: AudioDeviceID) -> Bool {
        let elements: [AudioObjectPropertyElement] = [kAudioObjectPropertyElementMain, 1, 2]
        for element in elements {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element)
            guard AudioObjectHasProperty(id, &addr) else { continue }
            var settable: DarwinBoolean = false
            if AudioObjectIsPropertySettable(id, &addr, &settable) == noErr, settable.boolValue {
                return true
            }
        }
        return false
    }
}
