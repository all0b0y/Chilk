import AppKit
import Carbon.HIToolbox

/// A global hotkey through Carbon's RegisterEventHotKey: works without Accessibility permission.
@MainActor
final class Hotkey {
    nonisolated(unsafe) private static var actions: [UInt32: () -> Void] = [:]
    nonisolated(unsafe) private static var handlerInstalled = false
    nonisolated(unsafe) private var ref: EventHotKeyRef?

    /// The call hotkey as shown to the user (menu, the «Слух сломался» bubble); Settings can change it (slice 5c).
    static var label = "⌃⌥Space"

    init?(keyCode: UInt32, modifiers: UInt32, id: UInt32, action: @escaping () -> Void) {
        Self.installHandler()
        Self.actions[id] = action
        let hotKeyID = EventHotKeyID(signature: OSType(0x4348_4C4B), id: id)          // 'CHLK'
        guard RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref) == noErr else { return nil }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
    }

    private static func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let key = id.id
            MainActor.assumeIsolated { Hotkey.actions[key]?() }               // Carbon delivers on the main thread
            return noErr
        }, 1, &spec, nil, nil)
    }
}
