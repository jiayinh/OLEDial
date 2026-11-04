import Carbon
import Foundation

/// Global hotkeys via Carbon's RegisterEventHotKey (no Accessibility permission needed).
final class HotKeyManager {
    static let shared = HotKeyManager()

    fileprivate var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var handlerInstalled = false
    private var nextID: UInt32 = 1

    func register(keyCode: Int, modifiers: Int, handler: @escaping () -> Void) {
        installHandlerIfNeeded()
        let id = nextID
        nextID += 1
        handlers[id] = handler
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4C47_5456), id: id) // 'LGTV'
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref { refs.append(ref) }
    }

    func unregisterAll() {
        for ref in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
        handlers.removeAll()
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                        EventParamType(typeEventHotKeyID), nil,
                                        MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard err == noErr else { return err }
            let id = hotKeyID.id
            DispatchQueue.main.async { HotKeyManager.shared.handlers[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
