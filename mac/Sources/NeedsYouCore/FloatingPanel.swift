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

/// The optional urgent edge glow (docs/roadmap/human-gates.md): a borderless, transparent
/// window over one display that draws a thin glow along its edge for a few seconds.
///
/// Same focus rule as the panel, and stricter: it ignores every mouse event (clicks go
/// straight through to whatever is under it), never becomes key or main, and is only ever
/// shown with `orderFrontRegardless()`. `FloatingPanelTests` guards this too.
public final class EdgeGlowWindow: NSPanel {
    public init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        collectionBehavior = FloatingPanel.requiredCollectionBehavior
        ignoresMouseEvents = true
        isFloatingPanel = true
        level = .statusBar   // after isFloatingPanel, which resets the level to .floating
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        isExcludedFromWindowsMenu = true
    }

    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }
}
#endif
