#if canImport(AppKit)
import AppKit

/// The answer window: where the person types their own answer to an agent's question
/// ("Other…" on a card whose question has `allowOther`, "Answer…" for one without options;
/// ADR 0009, amendment 2026-10-09).
///
/// Focus rule: the floating panel never takes focus and has no text fields, so typed words
/// can't go there. This is a separate, ordinary titled window that may become key, and it is
/// the second (and only other) exception besides Settings: it opens, and the app activates,
/// only from an explicit click on that card button. Never from a poll, an arrival, a timer
/// or a hotkey. It closes on Send or Cancel. `FloatingPanelTests` checks it is no
/// `FloatingPanel` and that the panel still can't become key.
public final class AnswerWindow: NSWindow {
    public static let defaultSize = NSSize(width: 440, height: 240)

    public init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        title = "Answer"
        level = .floating            // above the panel's cards it came from
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        appearance = NSAppearance(named: .darkAqua)
    }

    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { true }
}
#endif
