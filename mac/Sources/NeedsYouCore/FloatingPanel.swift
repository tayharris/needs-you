#if canImport(AppKit)
import AppKit

/// The needs-you floating panel.
///
/// Focus rule: the panel must NEVER take key or main status, and never activate the app.
/// The user is typing in some other app when items arrive, previews spring out, the
/// morning summary opens, or a snooze ends. So:
/// - `.nonactivatingPanel`: clicks don't activate the app.
/// - `canBecomeKey` / `canBecomeMain` are hard-wired to false. Buttons, links and menus
///   still work in a non-key panel (the hosting view accepts first mouse).
/// - Show and resize only with `orderFrontRegardless()` / `setFrame`, never
///   `makeKeyAndOrderFront`.
/// - Escape is handled by event monitors / a hotkey in the controller, not key status.
/// Nothing focusable (TextField, `.focusable`, `@FocusState`, text selection) may live in it.
/// `FloatingPanelTests` guards this.
public final class FloatingPanel: NSPanel {
    public static let requiredCollectionBehavior: NSWindow.CollectionBehavior = [
        .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle,
    ]

    public init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 60, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        // PLAN.md "Window behaviour": the part that went wrong before.
        level = .floating
        collectionBehavior = Self.requiredCollectionBehavior
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false            // dragging is handled explicitly so it can snap
        isReleasedWhenClosed = false
        animationBehavior = .none
        appearance = NSAppearance(named: .darkAqua)
        isExcludedFromWindowsMenu = true
    }

    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }
}
#endif
