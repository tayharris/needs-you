import NeedsYouCore
import SwiftUI

/// The "Alerts for This Session" and "Alerts for All <agent> Sessions" submenus of an agent
/// card's "…" menu (AlertRuleMenu has the state and edits). Plain menu buttons: choosing one
/// saves a bypass rule and never activates the app or makes the panel key (hard rule 2).
/// Draws nothing for a card that isn't an agent session's.
struct AlertRulesMenu: View {
    let item: Item
    @ObservedObject var model: AppModel

    var body: some View {
        let scopes = RuleScope.scopes(for: item)
        if !scopes.isEmpty {
            Divider()
            ForEach(scopes, id: \.self) { scope in
                Menu(scope.menuTitle) { ScopeMenu(scope: scope, model: model) }
            }
        }
    }
}

private struct ScopeMenu: View {
    let scope: RuleScope
    @ObservedObject var model: AppModel

    var body: some View {
        let book = model.settings.bypassRules
        actions(book: book, event: nil)
        Divider()
        ForEach(AlertRuleMenu.events, id: \.self) { event in
            Menu(event.menuTitle) { actions(book: book, event: event.rawValue) }
        }
        Divider()
        if let summary = AlertRuleMenu.summary(book, scope) {
            Text(summary)
        }
        Button("Remove Rules") { model.setBypassRules(AlertRuleMenu.removingAll(in: model.settings.bypassRules, scope)) }
            .disabled(!AlertRuleMenu.hasRules(book, scope))
        if book.isFull {
            Text("The list is full (\(RuleBook.maxRules) rules): remove some in Settings → Alerts")
        }
    }

    @ViewBuilder
    private func actions(book: RuleBook, event: String?) -> some View {
        let current = AlertRuleMenu.current(book, scope, event: event)
        ForEach(AlertRuleMenu.actions, id: \.self) { action in
            // A Toggle in a menu is a menu item with the system checkmark.
            Toggle(action.menuTitle, isOn: Binding(
                get: { current == action },
                set: { _ in
                    // The rules as they are at the click, not as the menu was drawn.
                    model.setBypassRules(AlertRuleMenu.choosing(action, in: model.settings.bypassRules, scope, event: event))
                }))
            .disabled(!AlertRuleMenu.canChoose(book, scope, event: event))
        }
    }
}
