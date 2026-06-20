import AppKit
import Carbon.HIToolbox

/// Регистрирует глобальные горячие клавиши через Carbon.
final class HotkeyManager {
    private struct Registered { var ref: EventHotKeyRef? }

    private var handlers: [UInt32: () -> Void] = [:]
    private var registered: [Registered] = []
    private var eventHandler: EventHandlerRef?
    private var counter: UInt32 = 1

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { (_, eventRef, userData) -> OSStatus in
            guard let eventRef, let userData else { return OSStatus(eventNotHandledErr) }
            let mgr = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            var hkID = EventHotKeyID()
            GetEventParameter(eventRef, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            if let handler = mgr.handlers[hkID.id] {
                DispatchQueue.main.async(execute: handler)
                return noErr
            }
            return OSStatus(eventNotHandledErr)
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &spec,
                            Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
    }

    /// keyCode — виртуальный код (kVK_*), modifiers — карбоновые флаги (cmdKey и т.п.).
    @discardableResult
    func register(keyCode: Int, modifiers: Int, handler: @escaping () -> Void) -> Bool {
        let id = counter
        counter += 1
        handlers[id] = handler
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x53534b59), id: id) // 'SSKY'
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr {
            registered.append(Registered(ref: ref))
            return true
        }
        handlers[id] = nil
        return false
    }

    func unregisterAll() {
        for item in registered {
            if let ref = item.ref { UnregisterEventHotKey(ref) }
        }
        registered.removeAll()
        handlers.removeAll()
    }

    deinit {
        unregisterAll()
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}
