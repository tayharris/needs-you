import AppKit
import NeedsYouCore
import SwiftUI

/// The answer window (ADR 0009, amendment 2026-10-09): the person's own words for an agent's
/// question, when its sender takes them (`allowOther`: Claude Code's and opencode's "Other").
/// It shows the question and a text field with Send and Cancel; Send hands the words to
/// AppModel (which sends the answer, or keeps the words for the card's Send when other
/// questions on the card still need a pick) and closes the window.
///
/// Focus rule: `show` is, with SettingsWindowController.show, the only place the app
/// activates or makes a window key, and it runs only from an explicit click on the card's
/// "Other…" / "Answer…" button (AppModel.openAnswerWindow). The panel stays non-key: the
/// text field lives here, in an ordinary window (`AnswerWindow`). When it closes, the app the
/// person was in before the click is brought back, unless Settings is open.
@MainActor
final class AnswerWindowController: NSObject, NSWindowDelegate {
    private var window: AnswerWindow?
    private let model: AppModel
    private var previousApp: NSRunningApplication?

    init(model: AppModel) {
        self.model = model
    }

    /// User-initiated only (see above).
    func show(item: Item, question: Int) {
        guard let q = item.question, q.items.indices.contains(question) else { return }
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = front }
        let plan = model.typedAnswerPlan(item.id, question: question)
        let view = AnswerSheet(
            item: item, question: question, initial: model.typedAnswer(item.id, question: question) ?? "",
            sends: plan.complete, with: plan.with,
            submit: { [weak self] text in
                guard let self else { return nil }
                let why = self.model.submitTypedAnswer(itemID: item.id, question: question, text: text,
                                                       seenVersion: item.contentUpdatedAtRaw)
                if why == nil { self.window?.performClose(nil) }
                return why
            },
            cancel: { [weak self] in self?.window?.performClose(nil) })
        let w = window ?? AnswerWindow()
        w.delegate = self
        w.contentViewController = NSHostingController(rootView: view)
        w.title = Self.title(item)
        w.setContentSize(AnswerWindow.defaultSize)
        if window == nil { w.center() }
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Back to what the person was doing, unless they're in Settings.
        let settingsFront = NSApp.windows.contains { $0.isVisible && $0.title.hasSuffix("Settings") }
        if let app = previousApp, !settingsFront, !app.isTerminated {
            _ = app.activate(options: [])
        }
        previousApp = nil
    }

    /// "Answer opencode on devbox · acme-web", from the item's source.
    static func title(_ item: Item) -> String { AnswerPolicy.windowTitle(item) }

    // MARK: Debug snapshot

    /// Debug aid (the snapshot tour, mac/scripts/screenshots.sh): draws the window for an
    /// item's question with `text` typed, into a PNG. The window is fully transparent and
    /// ignores the mouse: nobody sees it, it never becomes key and the app isn't activated.
    func writeSnapshot(item: Item, question: Int, text: String, to url: URL) async {
        let plan = model.typedAnswerPlan(item.id, question: question)
        let view = AnswerSheet(item: item, question: question, initial: text, sends: plan.complete, with: plan.with,
                               submit: { _ in nil }, cancel: {})
        let w = NSWindow(contentViewController: NSHostingController(rootView: view.environment(\.controlActiveState, .key)))
        w.title = Self.title(item)
        w.styleMask = [.titled, .closable]
        w.appearance = NSAppearance(named: .darkAqua)
        w.isReleasedWhenClosed = false
        w.alphaValue = 0
        w.ignoresMouseEvents = true
        w.setContentSize(AnswerWindow.defaultSize)
        w.orderFrontRegardless()   // never key, never activates: alpha 0 and no mouse
        defer { w.orderOut(nil) }
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        guard let content = w.contentView else { return }
        let frameView = content.superview ?? content
        frameView.layoutSubtreeIfNeeded()
        try? SnapshotImage.png(of: frameView)?.write(to: url)
    }
}

/// The window's content: the question, what the agent offered, the text field, and Send /
/// Cancel. The words are checked as the hub will check them (AnswerPolicy.typedAnswer) and
/// otherwise sent as typed.
private struct AnswerSheet: View {
    let item: Item
    let question: Int
    let sends: Bool
    let with: [String]
    let submit: (String) -> String?
    let cancel: () -> Void
    @State private var text: String
    @State private var problem: String?
    @SwiftUI.FocusState private var focused: Bool

    init(item: Item, question: Int, initial: String, sends: Bool, with: [String],
         submit: @escaping (String) -> String?, cancel: @escaping () -> Void) {
        self.item = item
        self.question = question
        self.sends = sends
        self.with = with
        self.submit = submit
        self.cancel = cancel
        _text = State(initialValue: initial)
    }

    var body: some View {
        let questions = item.question?.items ?? []
        let q = questions.indices.contains(question) ? questions[question] : ItemQuestionItem(text: "")
        VStack(alignment: .leading, spacing: 10) {
            Text(QuestionDisplay.heading(q, index: question, count: questions.count, answering: true))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(LimitedMarkdown.render(q.text))
                .font(.system(size: 13, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(6)
            if !q.options.isEmpty {
                Text("Its choices: " + q.options.map(\.label).joined(separator: " \u{00B7} "))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            TextField(q.options.isEmpty ? "Your answer" : "Your own answer", text: $text, axis: .vertical)
                .lineLimit(2...5)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(send)
                .onChange(of: text) { problem = nil }
            Group {
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                } else if sends {
                    Text(with.isEmpty ? "Send gives these words to the agent as your answer."
                                      : "Sent with your picks: " + with.joined(separator: " \u{00B7} "))
                        .foregroundStyle(.secondary)
                } else {
                    Text("The card keeps these words; Send there once every question has an answer.")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 11))
            .fixedSize(horizontal: false, vertical: true)
            Text(AnswerPolicy.windowWarning)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("\(text.unicodeScalars.count)/\(AnswerPolicy.maxTextLength)")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(text.unicodeScalars.count > AnswerPolicy.maxTextLength ? .orange : .secondary)
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button(sends ? "Send" : "Use", action: send)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: AnswerWindow.defaultSize.width, alignment: .topLeading)
        .onAppear { focused = true }
    }

    private func send() {
        problem = submit(text)
    }
}
