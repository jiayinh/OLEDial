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
