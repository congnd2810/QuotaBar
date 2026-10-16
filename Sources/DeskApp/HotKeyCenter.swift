import Carbon.HIToolbox

/// System-wide keyboard shortcuts via Carbon's RegisterEventHotKey, which (unlike event monitors)
/// needs no Accessibility permission.
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    /// ⌃⌥⌘ — rarely used by other apps.
    static let modifiers = UInt32(controlKey | optionKey | cmdKey)

    private var actions: [UInt32: () -> Void] = [:]
    private var registered: [EventHotKeyRef] = []
    private var nextID: UInt32 = 1

    private init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyHandler, 1, &spec, nil, nil)
    }

    func register(keyCode: Int, action: @escaping () -> Void) {
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4453_4B41), id: id) // "DSKA"
        guard RegisterEventHotKey(UInt32(keyCode), Self.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref) == noErr,
              let ref
        else { return }
        registered.append(ref)
        actions[id] = action
    }

    func unregisterAll() {
        registered.forEach { UnregisterEventHotKey($0) }
        registered.removeAll()
        actions.removeAll()
    }

    fileprivate func fire(_ id: UInt32) {
        actions[id]?()
    }
}

private func hotKeyHandler(_: EventHandlerCallRef?, _ event: EventRef?, _: UnsafeMutableRawPointer?) -> OSStatus {
    var hotKeyID = EventHotKeyID()
    GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
        nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
    )
    // Carbon delivers hot key events on the main thread.
    MainActor.assumeIsolated { HotKeyCenter.shared.fire(hotKeyID.id) }
    return noErr
}
