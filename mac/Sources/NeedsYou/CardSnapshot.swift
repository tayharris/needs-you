import AppKit
import NeedsYouCore
import SwiftUI

/// Debug aid for the format tour (NEEDS_YOU_SNAPSHOT_TOUR=formats, mac/scripts/screenshots.sh):
/// one card drawn on its own at the open panel's card width and at its whole height, so a
/// card taller than the list is seen in full. Like the Settings snapshots, the window is
/// borderless, transparent and ignores the mouse: never key, and the app never activates.
@MainActor
enum CardSnapshot {
    static func write(_ item: Item, model: AppModel, to url: URL) async {
        let m = model.metrics
        let view = CardView(item: item, model: model)
            .frame(width: m.expandedWidth - 2 * m.listPadding)
            .fixedSize(horizontal: false, vertical: true)
            .padding(m.listPadding)
            .environment(\.colorScheme, model.palette.isDark ? .dark : .light)
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try? await Task.sleep(nanoseconds: 300_000_000)
        host.layoutSubtreeIfNeeded()
        let background = model.palette.isDark ? NSColor(white: 0.13, alpha: 1) : NSColor(model.palette.surface)
        try? SnapshotImage.png(of: host, background: background)?.write(to: url)
    }
}
