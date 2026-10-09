import Foundation

// Settings → Appearance → Alert style: previewing an arrival. A preview plays what a real arrival does on the
// pill, from the state before the item came in to the state after: the pill springs out
// to the new-item preview while the arrival animation plays (glow, ripple and slide at
// once, bounce and shake once the spring has landed, as PanelController does), the
// preview stays out, then the pill springs back with the new count. Pure timing and
// sample data here (ArrivalMotionTests); the app draws it.

public enum ArrivalPreview {
    /// How long the panel's shape change takes (PanelController.sync, a changed shape).
    public static let springSeconds = 0.28
    /// Bounce and shake wait this long after the spring starts, so they play on the
    /// settled preview (PanelController.scheduleArrival).
    public static let settleDelay = 0.3

    /// Seconds after the item arrives that the animation starts: slide, glow and ripple at
    /// once (slide is the arrival itself), bounce and shake once the spring has landed.
    public static func motionDelay(_ animation: ArrivalAnimation) -> Double {
        switch animation {
        case .bounce, .shake: return settleDelay
        case .glow, .ripple, .slide, .none: return 0
        }
    }

    /// The sample item that "arrives" in a preview. Never posted, never counted.
    public static func sampleItem(_ priority: ItemPriority, now: Date = Date()) -> Item {
        let title: String
        switch priority {
        case .urgent: title = "Preview: an urgent item arrives"
        case .normal: title = "Preview: a normal item arrives"
        case .low: title = "Preview: a low item arrives"
        }
        return Item(id: "arrival-preview-\(priority.rawValue)", key: "arrival-preview-\(priority.rawValue)",
                    priority: priority, title: title,
                    source: ItemSource(host: "devbox", agent: "preview"), createdAt: now)
    }

    /// What was already waiting before the sample arrives (one low item), for the
    /// Settings preview's "before" pill.
    public static func waitingBefore(now: Date = Date()) -> [Item] {
        [Item(id: "arrival-preview-waiting", key: "arrival-preview-waiting", priority: .low,
              title: "Rotate the staging key", source: ItemSource(host: "devbox", agent: "cron"),
              createdAt: now.addingTimeInterval(-3600))]
    }

    /// One step of the Settings preview.
    public enum Stage: Equatable, Sendable {
        /// The pill as it was: what was already waiting.
        case before
        /// The item has arrived: the pill has sprung out to its preview.
        case arrived
        /// The preview has gone back: the pill with the new count.
        case after
    }

    /// The Settings preview's timeline for one arrival.
    public struct Script: Equatable, Sendable {
        /// Seconds the "before" pill shows first.
        public var lead: Double
        /// Seconds after the arrival that the animation starts.
        public var motionDelay: Double
        /// Seconds the preview stays out in Settings (shorter than the real one; see
        /// `realPreviewSeconds`).
        public var hold: Double
        /// Settings → Alerts → New items → Show new items for (0: until clicked or pointed at).
        public var realPreviewSeconds: Int

        /// When each stage starts, in seconds from the start.
        public var events: [(at: Double, stage: Stage)] {
            [(0, .before), (lead, .arrived), (lead + hold, .after)]
        }

        /// When the animation starts, in seconds from the start.
        public var motionStart: Double { lead + motionDelay }

        /// The whole preview, until the pill is back.
        public var totalSeconds: Double { lead + hold + ArrivalPreview.springSeconds }
    }

    /// The "before" pill shows this long first, so the change is visible.
    public static let lead = 0.7
    /// The preview stays out this long after the animation ends, at least `minHold` and at
    /// most `maxHold` in all unless the animation itself is longer (the real preview stays
    /// out `previewSeconds`).
    public static let afterMotion = 1.2
    public static let minHold = 2.0
    public static let maxHold = 8.0

    /// The script for `plan` with the user's preview time. The preview stays out for the
    /// real time when that's short, else long enough to see the whole animation.
    public static func script(_ plan: ArrivalPlan, previewSeconds: Int) -> Script {
        let delay = motionDelay(plan.animation)
        let motion = delay + plan.totalSeconds
        // Long enough to see the animation settle, capped, but never cutting it short.
        var hold = max(motion, min(maxHold, max(minHold, motion + afterMotion)))
        if previewSeconds > 0 { hold = min(hold, max(Double(previewSeconds), motion)) }
        return Script(lead: lead, motionDelay: delay, hold: hold, realPreviewSeconds: previewSeconds)
    }
}
