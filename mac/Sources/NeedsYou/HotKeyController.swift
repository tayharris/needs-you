import AppKit
import NeedsYouCore

/// Owns the global shortcut: registers the stored one at launch, re-registers when it's
/// changed in Settings, and records a new one (Settings window only, never the panel).
/// Nothing here activates the app or makes a window key.
@MainActor
final class HotKeyController: ObservableObject {
    /// The shortcut is registered with the system (false: another app or macOS has it).
    @Published private(set) var isRegistered = false
    /// The Settings recorder is waiting for a key press.
    @Published private(set) var isRecording = false

    private let settings: AppSettings
    private let action: () -> Void
    private var hotKey: HotKey?
    private var monitor: Any?
    private var onRecorded: ((String?) -> Void)?

    init(settings: AppSettings, action: @escaping () -> Void) {
        self.settings = settings
        self.action = action
        // A snapshot run (NEEDS_YOU_SNAPSHOT_DIR) sits next to the real app: leave the
        // shortcut to it.
        guard AppSettings.snapshotDirectory == nil else { return }
        if !register(settings.hotKey) {
            NSLog("NeedsYou: couldn't register \(settings.hotKey.display) (status \(hotKey?.status ?? -1)); is it bound to input-source switching?")
        }
    }

    var combo: HotKeyCombo { settings.hotKey }

    @discardableResult
    private func register(_ combo: HotKeyCombo) -> Bool {
        hotKey = nil   // unregister the old one first: the same id can't be registered twice
        let key = HotKey(id: 1, keyCode: combo.keyCode, modifiers: combo.modifiers, action: action)
        hotKey = key
        isRegistered = key.isRegistered
        return isRegistered
    }

    /// Switch to `new`. Returns nil when it worked; otherwise why not, and the old shortcut
    /// stays registered and stored.
    func change(to new: HotKeyCombo) -> String? {
        if let problem = HotKeyValidator.problem(with: new) { return problem.message }
        let old = settings.hotKey
        if register(new) {
            settings.hotKey = new
            return nil
        }
        register(old)
        return "\(new.spokenAndSymbols) is already used by another app or by macOS. Pick another shortcut."
    }

    // MARK: Recording (Settings window only)

    /// Waits for the next key press in this app (the Settings window is in front: the
    /// user just clicked its button). Esc cancels. `done` gets nil when the shortcut was
    /// changed or recording was cancelled, else a message; invalid presses keep recording.
    func startRecording(_ done: @escaping (String?) -> Void) {
        guard monitor == nil else { return }
        onRecorded = done
        isRecording = true
        // Let the current shortcut be typed (and not fire) while recording.
        hotKey = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = UInt32(event.keyCode)
            let modifiers = HotKeyController.carbonModifiers(event.modifierFlags)
            let swallow = MainActor.assumeIsolated { self?.recorded(keyCode: keyCode, modifiers: modifiers) ?? false }
            return swallow ? nil : event
        }
    }

    func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        onRecorded = nil
        guard isRecording else { return }
        isRecording = false
        if hotKey == nil { register(settings.hotKey) }
    }

    private func recorded(keyCode: UInt32, modifiers: UInt32) -> Bool {
        guard isRecording else { return false }
        let done = onRecorded
        if keyCode == KeyNames.escape && modifiers == 0 {
            stopRecording()
            done?(nil)
            return true
        }
        let combo = HotKeyCombo(keyCode: keyCode, modifiers: modifiers)
        if let problem = HotKeyValidator.problem(with: combo) {
            done?(problem.message)
            return true
        }
        stopRecording()
        done?(change(to: combo))
        return true
    }

    nonisolated static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= HotKeyCombo.command }
        if flags.contains(.shift) { m |= HotKeyCombo.shift }
        if flags.contains(.option) { m |= HotKeyCombo.option }
        if flags.contains(.control) { m |= HotKeyCombo.control }
        return m
    }

    nonisolated static func menuModifiers(_ combo: HotKeyCombo) -> NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if combo.modifiers & HotKeyCombo.command != 0 { f.insert(.command) }
        if combo.modifiers & HotKeyCombo.shift != 0 { f.insert(.shift) }
        if combo.modifiers & HotKeyCombo.option != 0 { f.insert(.option) }
        if combo.modifiers & HotKeyCombo.control != 0 { f.insert(.control) }
        return f
    }
}
