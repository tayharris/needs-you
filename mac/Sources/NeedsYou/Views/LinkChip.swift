import AppKit
import SwiftUI

/// The capsule behind a card's link button (the links row and step links). Lighter than
/// the card so links stand out; pointing at one brightens the fill and outline and shows
/// the pointing-hand cursor. Hover only: nothing here takes focus.
struct LinkChip: ViewModifier {
    var horizontal: CGFloat
    var vertical: CGFloat
    @State private var hovering = false
    @State private var cursorPushed = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, horizontal).padding(.vertical, vertical)
            .background(Capsule().fill(hovering ? Theme.linkFillHover : Theme.linkFill))
            .overlay(Capsule().strokeBorder(hovering ? Theme.linkStrokeHover : Theme.linkStroke, lineWidth: hovering ? 1 : 0.5))
            .foregroundStyle(Theme.linkText)
            .contentShape(Capsule())
            .onHover { inside in
                hovering = inside
                setPointingCursor(inside)
            }
            .onDisappear { setPointingCursor(false) }
            .animation(.easeOut(duration: 0.1), value: hovering)
    }

    private func setPointingCursor(_ on: Bool) {
        if on, !cursorPushed {
            NSCursor.pointingHand.push()
            cursorPushed = true
        } else if !on, cursorPushed {
            NSCursor.pop()
            cursorPushed = false
        }
    }
}

extension View {
    func linkChip(horizontal: CGFloat, vertical: CGFloat) -> some View {
        modifier(LinkChip(horizontal: horizontal, vertical: vertical))
    }
}
