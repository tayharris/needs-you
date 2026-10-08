import CoreGraphics
import Foundation

/// How the app was started, as far as launch behaviour cares.
public enum LaunchKind: String, Equatable, Sendable {
    /// The person opened it (Finder, Launchpad, Spotlight, `open`, Move to Applications).
    case byPerson
    /// macOS started it as a login item, or it came back with the session at login.
    case atLogin
    /// The self-updater's install.sh relaunched it a moment ago (`open -g`).
    case afterUpdate
}

/// The launch decision: started by the person, the panel opens once so they can see their
/// items (and that the app is running); at login or after an update, only the pill shows.
/// Opening never takes focus or activates the app: it's the same automatic expansion as
/// the morning summary, collapsed again by the pointer leaving, a click elsewhere, or
/// `seconds` going by.
public enum LaunchOpen {
    /// A launch this soon after the person logged in counts as a login launch, even when
    /// the login-item Apple event says nothing (macOS restoring apps at login, or an
    /// SMAppService login item launched without keyAELaunchedAsLogInItem).
    public static let loginWindow: TimeInterval = 120
    /// install.sh relaunches within seconds of the updater writing its attempt file; an
    /// older file is left from an install at quit (`--no-launch`), so this launch is the
    /// person's own.
    public static let updateWindow: TimeInterval = 120
    /// How long the launch open stays out with the pointer away (PeekCountdown: pointing
    /// at it holds it; it goes 2 s after the pointer leaves).
    public static let seconds = 10
    /// The open waits at most this long for the first poll, so the list isn't drawn empty
    /// for the wrong reason.
    public static let firstPollWait: TimeInterval = 4

    /// - Parameters:
    ///   - appleEventSaysLogin: the launch's open-application event carried
    ///     keyAELaunchedAsLogInItem.
    ///   - secondsSinceLogin: how long ago the console session began (nil: unknown).
    ///   - updateAttemptAge: how old the updater's attempt file is (nil: no file).
    public static func kind(appleEventSaysLogin: Bool, secondsSinceLogin: TimeInterval?,
                            updateAttemptAge: TimeInterval?) -> LaunchKind {
        if let age = updateAttemptAge, age >= 0, age < updateWindow { return .afterUpdate }
        if appleEventSaysLogin { return .atLogin }
        if let since = secondsSinceLogin, since >= 0, since < loginWindow { return .atLogin }
        return .byPerson
    }

    /// Open the panel at this launch? Only for a launch by the person, with Settings →
    /// Panel → Open the panel when Needs You starts on, a panel that isn't hidden (a hidden
    /// panel stays hidden), and not during the snapshot tour, which drives the panel itself.
    public static func shouldOpen(kind: LaunchKind, settingOn: Bool, panelHidden: Bool,
                                  snapshotTour: Bool = false) -> Bool {
        kind == .byPerson && settingOn && !panelHidden && !snapshotTour
    }
}

/// Why a saved pill placement can't be used as it is at launch.
public enum PlacementProblem: Equatable, Sendable {
    /// No connected screen has the placement's screen ID.
    case screenGone(String)
    /// The offset is negative, not a number, or absurd.
    case badOffset
    /// The pill at that placement would not lie fully on its screen's usable area.
    case offScreen

    public var description: String {
        switch self {
        case .screenGone(let id): return "its display (\(id)) isn't connected"
        case .badOffset: return "its offset is invalid"
        case .offScreen: return "it isn't fully on its display"
        }
    }
}

extension PanelGeometry {
    /// The frame for `placement` before it is clamped into `bounds`.
    public static func unclampedFrame(size: CGSize, placement: PanelPlacement, in bounds: CGRect,
                                      margin: CGFloat = margin) -> CGRect {
        let offset = placement.offset ?? CGSize(width: margin, height: margin)
        let corner = placement.corner
        let x = corner.isLeft ? bounds.minX + offset.width : bounds.maxX - offset.width - size.width
        let y = corner.isTop ? bounds.maxY - offset.height - size.height : bounds.minY + offset.height
        return CGRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }

    /// Checks a saved placement against the screens connected now. `screens` pairs each
    /// screen's ID (`screenID(_:)` of its frame) with the bounds the panel may use there
    /// (its visible frame, widened by the glow padding). `size` is the collapsed pill's
    /// panel size. nil: the pill at that placement is fully on its screen.
    public static func problem(with placement: PanelPlacement, size: CGSize,
                               screens: [(id: String, bounds: CGRect)], margin: CGFloat = margin) -> PlacementProblem? {
        guard let screen = screens.first(where: { $0.id == placement.screenID }) else {
            return .screenGone(placement.screenID)
        }
        if let o = placement.offset {
            let limit: CGFloat = 100_000
            guard o.width.isFinite, o.height.isFinite, o.width >= 0, o.height >= 0,
                  o.width < limit, o.height < limit else { return .badOffset }
        }
        let f = unclampedFrame(size: size, placement: placement, in: screen.bounds, margin: margin)
        // One point of slack for rounding.
        guard screen.bounds.insetBy(dx: -1, dy: -1).contains(f) else { return .offScreen }
        return nil
    }

    /// The placement to use at launch: the saved one when the pill fits fully on its
    /// screen, else nil (the default corner of the main display), with the reason.
    public static func launchPlacement(_ saved: PanelPlacement?, size: CGSize,
                                       screens: [(id: String, bounds: CGRect)],
                                       margin: CGFloat = margin) -> (placement: PanelPlacement?, problem: PlacementProblem?) {
        guard let saved else { return (nil, nil) }
        if let problem = problem(with: saved, size: size, screens: screens, margin: margin) { return (nil, problem) }
        return (saved, nil)
    }
}
