import AppKit
import NeedsYouCore
import SwiftUI

/// The strip on the open panel's free edge (the bottom, or the top when the panel sits on
/// a bottom corner and grows up) that drags the card list taller or shorter. Double-click
/// goes back to the automatic height. Like moving the panel by its header, the drag goes
/// to the panel controller through the model, so the panel never becomes key. Not
/// focusable: a plain shape with gestures.
struct ResizeGrip: View {
    @ObservedObject var model: AppModel
    @State private var hovering = false
    @State private var cursorPushed = false

    static let height: CGFloat = 9

    var body: some View {
        ZStack {
            Color.clear
            Capsule()
                .fill(Theme.text.opacity(hovering ? 0.5 : 0.2))
                .frame(width: hovering ? 44 : 32, height: 4)
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.height)
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            setResizeCursor(inside)
        }
        .onDisappear { setResizeCursor(false) }
        .gesture(
            DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .onChanged { _ in model.resizeHandler?(.changed) }
                .onEnded { _ in model.resizeHandler?(.ended) }
        )
        .onTapGesture(count: 2) { model.resetListHeight() }
        .help(model.settings.ui.expandedListHeight > 0
              ? "Drag to resize the list. Double-click for the automatic height."
              : "Drag to resize the list")
        .animation(.easeInOut(duration: 0.12), value: hovering)
    }

    /// The up-down resize cursor while the pointer is over the grip (push/pop, no focus).
    private func setResizeCursor(_ on: Bool) {
        if on, !cursorPushed {
            NSCursor.resizeUpDown.push()
            cursorPushed = true
        } else if !on, cursorPushed {
            NSCursor.pop()
            cursorPushed = false
        }
    }
}
