import NeedsYouCore
import SwiftUI

struct CardView: View {
    let item: Item
    @ObservedObject var model: AppModel

    var body: some View {
        let m = model.metrics
        HStack(alignment: .top, spacing: 9) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Theme.color(item.priority))
                .frame(width: 3)
                .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 5) {
                let badge = CardAge.badge(createdAt: item.createdAt, now: model.now)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(item.title)
                        .font(Theme.title(m))
                        .foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(item.key)
                    if let badge {
                        Spacer(minLength: 0)
                        AgeBadge(text: badge, stale: CardAge.isStale(createdAt: item.createdAt, now: model.now), metrics: m)
                    }
                }

                Text(Format.meta(item, now: model.now, includeAge: badge == nil))
                    .font(Theme.meta(m))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)

                if model.settings.developerMode {
                    // Developer mode: the key, for bug reports (the "…" menu copies it).
                    Text(item.key)
                        .font(.system(size: m.metaFont, design: .monospaced))
                        .foregroundStyle(Theme.faint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(item.key)
                }

                let mode = model.settings.ui.cardBodies
                let expanded = model.expandedCards.contains(item.id)
                // With a question drawn as rows, the body's copy of it is left out (QuestionDisplay.body),
                // and what's left ("Answer in Claude.", the folder and session) comes after the question.
                let body = QuestionDisplay.body(item)
                if item.question == nil, let body, CardBodyPolicy.showsBody(mode, expanded: expanded) {
                    CardBodyText(text: body, mode: mode, expanded: expanded, model: model)
                    CommandChips(item: item, text: body, model: model)
                }

                if !item.steps.isEmpty {
                    if StepsPolicy.showsList(mode, expanded: expanded) {
                        StepList(item: item, model: model)
                            .padding(.top, 1)
                    } else {
                        Button { model.toggleCardExpanded(item) } label: {
                            Label(StepsPolicy.summary(total: item.steps.count, ticked: model.stepTicks.tickedCount(item)),
                                  systemImage: "checklist")
                                .font(Theme.meta(m))
                                .foregroundStyle(Theme.muted)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Show the steps")
                    }
                }

                if let question = item.question {
                    if QuestionDisplay.showsAll(mode, expanded: expanded) {
                        QuestionList(item: item, question: question, model: model)
                            .padding(.top, 1)
                    } else {
                        Button { model.toggleCardExpanded(item) } label: {
                            Label(QuestionDisplay.summary(question), systemImage: "questionmark.bubble")
                                .font(Theme.meta(m))
                                .foregroundStyle(Theme.muted)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Show the question and its choices")
                    }
                    if let body, CardBodyPolicy.showsBody(mode, expanded: expanded) {
                        CardBodyText(text: body, mode: mode, expanded: expanded, model: model)
                        CommandChips(item: item, text: body, model: model)
                    }
                }

                if StepsPolicy.canExpand(item, mode: mode) || QuestionDisplay.canExpand(item, mode: mode)
                    || CardBodyPolicy.canExpand(body: body, mode: mode),
                   expanded || CardBodyPolicy.canExpand(body: body, mode: mode) {
                    Button(CardBodyPolicy.toggleTitle(mode, expanded: expanded)) { model.toggleCardExpanded(item) }
                        .buttonStyle(.plain)
                        .font(Theme.meta(m))
                        .foregroundStyle(Theme.muted)
                }

                if !AnswerPolicy.rowLinks(item, sent: model.answerStates[item.id] == .sent).isEmpty {
                    LinkRow(item: item, model: model)
                        .padding(.top, 2)
                }

                if let setup = model.setupCard(for: item) {
                    // A local setup tip: its own buttons, nothing that PATCHes a hub.
                    SetupCardActions(card: setup, model: model)
                        .padding(.top, 2)
                } else {
                    CardActions(item: item, model: model)
                        .padding(.top, 2)
                }
            }
        }
        .padding(m.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.cardFill))
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: CardBottomsKey.self, value: [proxy.frame(in: .named(CardBottomsKey.space)).maxY])
            }
        )
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
        // Opened at this card (the clicked preview, or the newest arrival): a brief outline.
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.color(item.priority), lineWidth: 1.5)
                .opacity(model.highlightedItem == item.id ? 0.9 : 0)
                .animation(.easeOut(duration: 0.6), value: model.highlightedItem)
        )
        .id(item.id)
    }
}

/// The card's body text (limited markdown), cut to the card text mode's lines.
private struct CardBodyText: View {
    let text: String
    let mode: CardBodyMode
    let expanded: Bool
    @ObservedObject var model: AppModel

    var body: some View {
        Text(LimitedMarkdown.render(text))
            .font(Theme.body(model.bodyFont))
            .foregroundStyle(Theme.text.opacity(0.85))
            .tint(Theme.accent)
            .lineLimit(CardBodyPolicy.lineLimit(mode, expanded: expanded))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The body's commands, paths and ids (CardCopy.snippets) as copy chips: a click puts the
/// snippet on the clipboard, exactly the text the chip shows (never truncated; unsafe
/// snippets get no chip), and the chip says "Copied" for a moment. The panel is
/// never key, so the body's text can't be selected; these are how a command gets out.
/// Plain buttons like the link chips: nothing here takes focus.
private struct CommandChips: View {
    let item: Item
    let text: String
    @ObservedObject var model: AppModel

    var body: some View {
        let snippets = CardCopy.snippets(in: text)
        if !snippets.isEmpty {
            FlowLayout(spacing: 4, lineSpacing: 4) {
                ForEach(snippets, id: \.self) { snippet in
                    let copied = model.copied.map { $0.itemID == item.id && $0.inPlace && $0.text == snippet } ?? false
                    Button { model.copy(snippet, from: item, what: "command", inPlace: true) } label: {
                        HStack(spacing: 4) {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: max(8, model.metrics.linkFont - 2), weight: .semibold))
                            // The whole snippet, wrapped, never cut: what's copied is what's shown
                            // (CardCopy.isSafeSnippet keeps it to one short line of visible text).
                            Text(copied ? "Copied" : snippet)
                                .font(.system(size: model.metrics.linkFont, design: .monospaced))
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .linkChip(horizontal: 7, vertical: 2)
                    }
                    .buttonStyle(.plain)
                    .help("Copy: \(snippet)")
                }
            }
            .padding(.top, 1)
        }
    }
}

/// Allowed links are buttons that open via NSWorkspace; anything else is plain text.
struct LinkRow: View {
    let item: Item
    @ObservedObject var model: AppModel

    var body: some View {
        let compact = model.settings.ui.compactLinks
        // On a question card "Answer in the terminal" is the terminal button; the link isn't repeated.
        let links = AnswerPolicy.rowLinks(item, sent: model.answerStates[item.id] == .sent)
        let plan = LinkRowPolicy.plan(links, compact: compact, expanded: model.expandedCards.contains(item.id))
        FlowLayout(spacing: compact ? 4 : 6, lineSpacing: compact ? 4 : 6) {
            ForEach(Array(plan.shown.enumerated()), id: \.offset) { _, link in
                if LinkPolicy.isAllowed(link.url) {
                    Button {
                        model.open(link.url, from: item)
                    } label: {
                        HStack(spacing: 3) {
                            Text(LinkRowPolicy.label(link, maxLength: plan.maxLabelLength)).lineLimit(1)
                            if let destination = LinkRowPolicy.destination(link) {
                                // Where it really goes, so a label can't pass for another site.
                                Text(destination)
                                    .fontWeight(.regular)
                                    .foregroundStyle(Theme.linkDestination)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Image(systemName: "arrow.up.right").font(.system(size: 8, weight: .bold))
                        }
                        .font(.system(size: model.metrics.linkFont, weight: .medium))
                        .linkChip(horizontal: compact ? 6 : 8, vertical: compact ? 2 : 3)
                    }
                    .buttonStyle(.plain)
                    .help(link.url)
                } else {
                    Text("\(link.label): \(link.url)")
                        .font(.system(size: model.metrics.linkFont))
                        .foregroundStyle(Theme.faint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help("Not opened: link scheme isn't on the allow-list")
                }
            }
            if plan.overflow > 0 {
                Button("+\(plan.overflow)") { model.toggleCardExpanded(item) }
                    .buttonStyle(.plain)
                    .font(.system(size: model.metrics.linkFont, weight: .medium))
                    .foregroundStyle(Theme.muted)
                    .padding(.vertical, 2)
                    .help("Show all links")
            }
        }
    }
}

/// The item's steps as a numbered checklist at the card text size. The tick box and the
/// step's link are plain buttons, like every other card control: the panel never becomes
/// key (FloatingPanel), so clicking them never takes focus. Ticks are local to this Mac.
struct StepList: View {
    let item: Item
    @ObservedObject var model: AppModel

    var body: some View {
        let font = model.bodyFont
        let steps = StepsPolicy.visible(item)
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                let ticked = model.stepTicks.isTicked(item, index)
                let toggles = model.stepTicks.canToggle(item, index)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Button { model.toggleStep(item, index) } label: {
                        Image(systemName: ticked ? "checkmark.square.fill" : "square")
                            .font(.system(size: font))
                            .foregroundStyle(ticked ? Theme.accent.opacity(toggles ? 0.9 : 0.6) : Theme.muted)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!toggles)
                    .help(toggles ? (ticked ? "Untick (only on this Mac)" : "Tick off (only on this Mac)") : "Marked done by the sender")

                    // As wide as the last number, so "10." doesn't push its text past the others.
                    ZStack(alignment: .trailing) {
                        Text(StepsPolicy.number(steps.count - 1)).hidden()
                        Text(StepsPolicy.number(index))
                    }
                    .font(Theme.body(font).monospacedDigit())
                    .foregroundStyle(Theme.muted)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(LimitedMarkdown.render(step.text))
                            .strikethrough(ticked, color: Theme.text.opacity(0.35))
                            .font(Theme.body(font))
                            .foregroundStyle(Theme.text.opacity(ticked ? 0.45 : 0.85))
                            .tint(Theme.accent)
                            .fixedSize(horizontal: false, vertical: true)
                        if let link = step.link {
                            StepLinkButton(item: item, link: link, model: model)
                        }
                    }
                }
            }
            if model.stepTicks.allTicked(item) {
                Button { model.resolve(item) } label: {
                    Label("All steps done: mark Done", systemImage: "checkmark.circle.fill")
                        .font(.system(size: model.metrics.actionFont, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
    }
}

/// An agent's question (`question`, ADR 0009): each question under its header with "choose
/// one" or "choose any", then its options as rows, the label and a fainter description. No
/// tick boxes. When the sender waits for an answer (`answerable`, AnswerPolicy.canAnswer) the
/// rows are buttons: for one single-choice question a click sends that answer; otherwise
/// clicks toggle and Send sends. A question whose sender takes the person's own words
/// (`allowOther`) gets "Other…" ("Answer…" without options), which opens the answer window:
/// the only card button that activates the app, since typing needs a key window and the
/// panel never is one. "Answer in the terminal" opens the card's terminal link. Every other
/// control is a plain button: the panel never becomes key.
struct QuestionList: View {
    let item: Item
    let question: ItemQuestion
    @ObservedObject var model: AppModel

    var body: some View {
        let font = model.bodyFont
        let items = QuestionDisplay.visible(question)
        let answering = AnswerPolicy.canAnswer(item, now: model.now)
        let state = model.answerStates[item.id]
        let selection = model.answerSelections[item.id] ?? AnswerSelection()
        let locked = state == .sending || state == .sent
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, q in
                VStack(alignment: .leading, spacing: 4) {
                    Text(QuestionDisplay.heading(q, index: index, count: items.count, answering: answering))
                        .font(.system(size: model.metrics.metaFont, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                    Text(LimitedMarkdown.render(q.text))
                        .font(Theme.body(font).weight(.medium))
                        .foregroundStyle(Theme.text.opacity(0.92))
                        .tint(Theme.normal)
                        .fixedSize(horizontal: false, vertical: true)
                    if !q.options.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(q.options.enumerated()), id: \.offset) { _, option in
                                let chosen = selection.isPicked(index, option.label)
                                    || (item.answer?.indices.contains(index) == true
                                        && item.answer![index].selected.contains(option.label))
                                if answering && !locked {
                                    Button { model.pickOption(item, question: index, label: option.label) } label: {
                                        OptionRow(option: option, font: font, chosen: chosen, clickable: true,
                                                  multiSelect: q.multiSelect && !AnswerPolicy.sendsOnClick(question))
                                    }
                                    .buttonStyle(.plain)
                                    .help(AnswerPolicy.sendsOnClick(question)
                                          ? "Answer \u{201C}\(option.label)\u{201D}"
                                          : (chosen ? "Unselect" : "Select"))
                                } else {
                                    OptionRow(option: option, font: font, chosen: chosen, clickable: false,
                                              multiSelect: false)
                                }
                            }
                        }
                        .padding(.top, 1)
                    }
                    TypedAnswerRow(item: item, index: index, question: q, model: model, font: font,
                                   answering: answering, locked: locked, typed: selection.texts[index])
                }
            }
            AnswerFooter(item: item, question: question, model: model, answering: answering,
                         state: state, selection: selection)
        }
    }
}

/// Below the options: Send (several questions or multi-select), "Answer in the terminal",
/// and where the answer stands.
private struct AnswerFooter: View {
    let item: Item
    let question: ItemQuestion
    @ObservedObject var model: AppModel
    let answering: Bool
    let state: AnswerState?
    let selection: AnswerSelection

    var body: some View {
        let m = model.metrics
        let terminal = AnswerPolicy.terminalLink(item)
        VStack(alignment: .leading, spacing: 4) {
            if let answered = AnswerPolicy.answeredText(item) {
                Label(answered, systemImage: "checkmark.circle.fill")
                    .font(.system(size: m.metaFont, weight: .medium))
                    .foregroundStyle(Theme.normal.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            } else if let state {
                switch state {
                case .sending:
                    Label("Sending…", systemImage: "paperplane")
                        .font(.system(size: m.metaFont)).foregroundStyle(Theme.muted)
                case .sent:
                    Label("Sent to the agent", systemImage: "checkmark.circle")
                        .font(.system(size: m.metaFont, weight: .medium)).foregroundStyle(Theme.normal.opacity(0.9))
                case .failed(let why):
                    Label(why, systemImage: "exclamationmark.triangle")
                        .font(.system(size: m.metaFont))
                        .foregroundStyle(Theme.urgent.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if answering || terminal != nil {
                HStack(spacing: 12) {
                    if answering, !AnswerPolicy.sendsOnClick(question), state != .sending, state != .sent {
                        let ready = selection.isComplete(for: question)
                        Button { model.sendPickedAnswer(item) } label: {
                            Label("Send", systemImage: "paperplane.fill")
                                .font(.system(size: m.actionFont, weight: .semibold))
                                .foregroundStyle(ready ? Theme.normal : Theme.faint)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!ready)
                        .help(ready ? "Send these choices to the agent" : "Choose an option for every question first")
                    }
                    if let terminal, AnswerPolicy.showsTerminalButton(item, sent: state == .sent) {
                        Button { model.open(terminal.url, from: item) } label: {
                            Label("Answer in the terminal", systemImage: "terminal")
                                .font(.system(size: m.actionFont))
                                .foregroundStyle(Theme.muted)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Bring the agent's terminal forward (for an answer the card can't give)")
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

/// Below a question's options, when its sender takes typed words: "Other…" ("Answer…"),
/// which opens the answer window; the words once typed (click to edit, × to take them back
/// before Send); or the words of the answer given.
private struct TypedAnswerRow: View {
    let item: Item
    let index: Int
    let question: ItemQuestionItem
    @ObservedObject var model: AppModel
    let font: CGFloat
    let answering: Bool
    let locked: Bool
    let typed: String?

    var body: some View {
        let given = item.answer.flatMap { $0.indices.contains(index) ? $0[index].text : nil }
        if let given {
            OptionRow(option: words(given, "Your own words"), font: font, chosen: true)
        } else if let typed, answering, !locked {
            HStack(spacing: 4) {
                Button { model.openAnswerWindow(item, question: index) } label: {
                    OptionRow(option: words(typed, "Your own words \u{00B7} click to change"), font: font,
                              chosen: true, clickable: true)
                }
                .buttonStyle(.plain)
                .help("Change your answer")
                Button { model.clearTypedAnswer(item, question: index) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: max(10, font - 1)))
                        .foregroundStyle(Theme.muted)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Take these words back")
            }
        } else if let typed {
            OptionRow(option: words(typed, "Your own words"), font: font, chosen: true)
        } else if answering, let title = AnswerPolicy.otherTitle(question) {
            Button { model.openAnswerWindow(item, question: index) } label: {
                OptionRow(option: ItemQuestionOption(label: title, detail: question.options.isEmpty
                                                     ? "Type your answer" : "Type your own answer"),
                          font: font, clickable: true)
            }
            .buttonStyle(.plain)
            .help("Opens a small window to type your answer in")
        }
    }

    private func words(_ text: String, _ detail: String) -> ItemQuestionOption {
        ItemQuestionOption(label: "\u{201C}\(text)\u{201D}", detail: detail)
    }
}

/// One choice: its label, and its description in a fainter colour below it. Clickable rows
/// get a stronger outline; a chosen one (picked, or the answer given) is tinted.
struct OptionRow: View {
    let option: ItemQuestionOption
    let font: CGFloat
    var chosen = false
    var clickable = false
    var multiSelect = false
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(option.label)
                    .font(Theme.body(font).weight(.semibold))
                    .foregroundStyle(Theme.text.opacity(0.92))
                    .fixedSize(horizontal: false, vertical: true)
                if !option.detail.isEmpty {
                    Text(option.detail)
                        .font(Theme.body(max(9, font - 1)))
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if chosen {
                Image(systemName: "checkmark")
                    .font(.system(size: max(9, font - 2), weight: .bold))
                    .foregroundStyle(Theme.normal)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(chosen ? Theme.normal.opacity(0.16) : Theme.text.opacity(clickable ? (hovering ? 0.16 : 0.1) : 0.06)))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(chosen ? Theme.normal.opacity(0.6) : (clickable ? Theme.linkStroke : Theme.hairline),
                          lineWidth: chosen || clickable ? 1 : 0.5))
        .contentShape(Rectangle())
        .onHover { hovering = clickable && $0 }
    }
}

/// A step's link: a small button when its scheme is allowed, plain text otherwise.
private struct StepLinkButton: View {
    let item: Item
    let link: ItemLink
    @ObservedObject var model: AppModel

    var body: some View {
        if LinkPolicy.isAllowed(link.url) {
            Button {
                model.open(link.url, from: item)
            } label: {
                HStack(spacing: 3) {
                    Text(StepsPolicy.linkTitle(link)).lineLimit(1)
                    if let destination = LinkRowPolicy.destination(link) {
                        // Where it really goes, as on the links row.
                        Text(destination)
                            .fontWeight(.regular)
                            .foregroundStyle(Theme.linkDestination)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Image(systemName: "arrow.up.right").font(.system(size: 8, weight: .bold))
                }
                .font(.system(size: model.metrics.linkFont, weight: .medium))
                .linkChip(horizontal: 7, vertical: 2)
            }
            .buttonStyle(.plain)
            .help(link.url)
        } else {
            Text("\(link.label): \(link.url)")
                .font(.system(size: model.metrics.linkFont))
                .foregroundStyle(Theme.faint)
                .lineLimit(1)
                .truncationMode(.middle)
                .help("Not opened: link scheme isn't on the allow-list")
        }
    }
}

struct CardActions: View {
    let item: Item
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            ActionButton(title: "Done", symbol: "checkmark", size: model.metrics.actionFont) { model.resolve(item) }
            ActionButton(title: "Dismiss", symbol: "xmark", size: model.metrics.actionFont) { model.dismiss(item) }
            Menu {
                ForEach(SnoozeOption.cardChoices) { option in
                    Button(option.title) { model.snoozeCard(item, option) }
                }
            } label: {
                Label("Snooze", systemImage: "clock")
                    .font(.system(size: model.metrics.actionFont))
                    .foregroundStyle(Theme.muted)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            Spacer()
            if let notice = model.copied, notice.itemID == item.id, !notice.inPlace {
                Label("Copied \(notice.what)", systemImage: "checkmark")
                    .font(.system(size: model.metrics.metaFont))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                    .transition(.opacity)
            }
            Menu {
                CardMenuItems(item: item, model: model)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: model.metrics.actionFont, weight: .semibold))
                    .foregroundStyle(Theme.muted)
                    .frame(width: 18)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Copy, and more")
        }
    }
}

/// The card's "…" menu: copying (the panel is never key, so text can't be selected),
/// Dismiss All from the host, and in Developer mode the item itself for bug reports.
private struct CardMenuItems: View {
    let item: Item
    @ObservedObject var model: AppModel

    var body: some View {
        Button("Copy Title and Text") { model.copy(CardCopy.titleAndText(item), from: item, what: "text") }
        if let urls = CardCopy.linkURLs(item) {
            Button(item.links.count == 1 ? "Copy Link URL" : "Copy Link URLs") { model.copy(urls, from: item, what: "links") }
        }
        let commands = CardCopy.snippets(in: item.body)
        if commands.count == 1, let command = commands.first {
            Button("Copy Command") { model.copy(command, from: item, what: "command") }
        } else if commands.count > 1 {
            Menu("Copy Command") {
                ForEach(commands, id: \.self) { command in
                    Button(command) { model.copy(command, from: item, what: "command") }
                }
            }
        }
        if let host = ItemStore.host(of: item) {
            Divider()
            let count = model.itemsFromSameHost(as: item).count
            Button("Dismiss All from \(host) (\(count))") { model.dismissAll(fromHostOf: item) }
        }
        AlertRulesMenu(item: item, model: model)
        if model.settings.developerMode {
            Divider()
            Section("Developer") {
                Button("Copy Item JSON") { model.copy(CardCopy.itemJSON(item), from: item, what: "JSON") }
                Button("Copy Key") { model.copy(item.key, from: item, what: "key") }
                Button("Copy ID") { model.copy(item.id, from: item, what: "ID") }
                Button("Copy Debug Report") {
                    model.copy(CardCopy.debugReport(item, info: model.debugInfo(for: item)), from: item, what: "report")
                }
                Button("Copy as needs-you add Command") {
                    model.copy(CardCopy.addCommand(item), from: item, what: "add command")
                }
            }
        }
    }
}

/// A setup card's row: its buttons (Open Settings, Copy agent prompt) and Dismiss, plus
/// the result of the last button press. Plain buttons, like every card control: the panel
/// never becomes key.
struct SetupCardActions: View {
    let card: SetupCard
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let notice = model.setupNotice, notice.tip == card.tip {
                Text(notice.text)
                    .font(Theme.meta(model.metrics))
                    .foregroundStyle(notice.failed ? Theme.urgent.opacity(0.85) : Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                ForEach(Array(card.buttons.enumerated()), id: \.offset) { _, button in
                    ActionButton(title: button.title, symbol: button.symbol, size: model.metrics.actionFont) {
                        model.runSetup(button.action, for: card.tip)
                    }
                }
                if card.dismissible {
                    ActionButton(title: "Dismiss", symbol: "xmark", size: model.metrics.actionFont) {
                        model.dismissSetupTip(card.tip)
                    }
                    .help("Don't show this tip again (Settings → Panel → Setup tips brings it back)")
                }
                Spacer()
            }
        }
    }
}

/// "5 h" / "2 d" next to an old card's title; amber once it's probably stale.
private struct AgeBadge: View {
    let text: String
    let stale: Bool
    let metrics: PanelMetrics

    var body: some View {
        Text(text)
            .font(.system(size: metrics.metaFont, weight: .medium).monospacedDigit())
            .foregroundStyle(stale ? Theme.normal.opacity(0.9) : Theme.muted)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(Theme.text.opacity(stale ? 0.10 : 0.06)))
            .fixedSize()
            .help(stale ? "Waiting a long time: it may be stale. Dismiss it, or all from this host (… menu)." : "Waiting since this long ago")
    }
}

private struct ActionButton: View {
    let title: String
    let symbol: String
    var size: CGFloat = 11
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: size))
                .foregroundStyle(Theme.muted)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Compact row for done / info items in "Recent". Never counted.
struct RecentRow: View {
    let item: Item
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: item.kind == .done ? "checkmark.circle" : "info.circle")
                .font(.system(size: model.metrics.metaFont))
                .foregroundStyle(Theme.muted)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(Theme.body(model.bodyFont))
                    .foregroundStyle(Theme.text.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
                Text(Format.meta(item, now: model.now))
                    .font(Theme.meta(model.metrics))
                    .foregroundStyle(Theme.faint)
                if !item.links.isEmpty {
                    LinkRow(item: item, model: model)
                }
            }
            Spacer(minLength: 0)
            Button { model.dismiss(item) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.faint)
            .help("Dismiss")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }
}

/// A simple wrapping row layout for link buttons.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, min(x - spacing, maxWidth))
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: widest, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: min(size.width, bounds.width), height: size.height))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
