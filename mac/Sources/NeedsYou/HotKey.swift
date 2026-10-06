import Carbon
import Foundation

/// A system-wide hotkey via Carbon's RegisterEventHotKey. Unlike a global NSEvent key
/// monitor, this needs no Accessibility permission. It never activates the app.
final class HotKey {
    private static let signature = OSType(0x4E_59_4F_55) // 'NYOU'

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let id: UInt32
    private let action: () -> Void
    private(set) var status: OSStatus = noErr

    /// ⌃⌥Space by default. Each live HotKey needs a distinct `id`.
    init(id: UInt32 = 1, keyCode: UInt32 = UInt32(kVK_Space), modifiers: UInt32 = UInt32(controlKey | optionKey), action: @escaping () -> Void) {
        self.id = id
        self.action = action

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        status = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var pressed = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            // Every handler sees every hotkey event; only act on our own.
            guard err == noErr, pressed.signature == HotKey.signature, pressed.id == hotKey.id else {
                return OSStatus(eventNotHandledErr)
            }
            DispatchQueue.main.async { hotKey.action() }
            return noErr
        }, 1, &spec, context, &handlerRef)
        guard status == noErr else { return }

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    var isRegistered: Bool { status == noErr && hotKeyRef != nil }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
