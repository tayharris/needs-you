#if canImport(AppKit)
import AppKit

/// The notes window: where the person types their notes (ADR 0014). A plain markdown editor
/// beside a preview, with Save and Cancel.
///
/// Focus rule: the floating panel never takes focus and has no text fields. This is a
/// separate, ordinary titled window that may become key: with Settings and the answer window,
/// the third and last exception. It opens, and the app activates, only from an explicit
/// click on the Notes view's Edit button. Never from a poll, an arrival, a timer or a
/// hotkey. `FloatingPanelTests` checks it is no `FloatingPanel`.
public final class NotesWindow: NSWindow {
    public static let defaultSize = NSSize(width: 720, height: 460)

    public init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: true
        )
        title = "Notes"
        level = .floating            // above the panel it came from
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        appearance = NSAppearance(named: .darkAqua)
        minSize = NSSize(width: 480, height: 300)
    }

    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { true }
}
#endif
