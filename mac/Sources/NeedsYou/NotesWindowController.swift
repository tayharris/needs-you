import AppKit
import NeedsYouCore
import SwiftUI

/// The notes window (ADR 0014): the person's notes as markdown, with a live preview, Save
/// and Cancel. Save sends the whole text on the rev the window opened with; if the notes
/// changed elsewhere meanwhile (an agent's `notes add`, another Mac), it says so and offers
/// Reload or Save Mine.
///
/// Focus rule: `show` runs only from an explicit click on the Notes view's Edit button
/// (AppModel.openNotesWindow). With Settings and the answer window it is the only place the
/// app activates or makes a window key; the panel stays non-key. When it closes, the app the
/// person was in before the click is brought back, unless Settings is open.
@MainActor
final class NotesWindowController: NSObject, NSWindowDelegate {
    private var window: NotesWindow?
    private let model: AppModel
    private var previousApp: NSRunningApplication?

    init(model: AppModel) {
        self.model = model
    }

    /// User-initiated only (see above).
    func show() {
        guard let doc = model.notes else { return }
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = front }
        if let window, window.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let view = NotesEditor(model: model, initial: doc, close: { [weak self] in self?.window?.performClose(nil) })
        let w = window ?? NotesWindow()
        w.delegate = self
        w.contentViewController = NSHostingController(rootView: view)
        w.setContentSize(NotesWindow.defaultSize)
        if window == nil { w.center() }
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        let settingsFront = NSApp.windows.contains { $0.isVisible && $0.title.hasSuffix("Settings") }
        if let app = previousApp, !settingsFront, !app.isTerminated {
            _ = app.activate(options: [])
        }
        previousApp = nil
    }
}

private struct NotesEditor: View {
    @ObservedObject var model: AppModel
    let close: () -> Void
    @State private var text: String
    @State private var baseRev: String
    @State private var problem: String?
    @State private var conflict = false
    @State private var saving = false
    @SwiftUI.FocusState private var focused: Bool

    init(model: AppModel, initial: NotesDocument, close: @escaping () -> Void) {
        self.model = model
        self.close = close
        _text = State(initialValue: initial.text)
        _baseRev = State(initialValue: initial.rev)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Markdown").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    TextEditor(text: $text)
                        .font(.system(size: 13, design: .monospaced))
                        .focused($focused)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.25)))
                        .onChange(of: text) { problem = nil }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Preview").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    ScrollView {
                        NotesPreview(text: text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.04)))
                }
            }
            Text("`## Heading`, `- [ ] todo`, `- [x] done`, `- bullet`, **bold**, *italic*, `[label](https://…)`. Links open only for allowed schemes. Never put passwords or tokens here: notes sync to your hubs.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if conflict {
                HStack(spacing: 8) {
                    Label("The notes changed elsewhere since you opened them.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Reload (drop my edits)") { Task { await reload() } }
                    Button("Save Mine") { Task { await overwrite() } }
                }
                .font(.system(size: 11))
            } else if let problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
            HStack {
                Text("\(text.count)/\(NotesText.maxLength)")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(text.count > NotesText.maxLength ? .orange : .secondary)
                Spacer()
                Button("Cancel", action: close)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { Task { await save(rev: baseRev) } }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(saving || conflict)
            }
        }
        .padding(16)
        .frame(minWidth: 480, minHeight: 300)
        .onAppear { focused = true }
    }

    private func save(rev: String) async {
        if let why = NotesText.problem(text) {
            problem = why
            return
        }
        saving = true
        defer { saving = false }
        switch await model.saveNotes(text: text, baseRev: rev) {
        case .saved?:
            close()
        case .conflict?:
            conflict = true
        case let .refused(_, message)?:
            problem = message.isEmpty ? "The hub refused the notes." : message
        case nil:
            problem = "Couldn't reach the hub; nothing was saved."
        }
    }

    private func reload() async {
        guard let doc = await model.reloadNotes() else {
            problem = "Couldn't reach the hub."
            return
        }
        text = doc.text
        baseRev = doc.rev
        conflict = false
    }

    /// Mine replaces theirs: take the current rev and save on it.
    private func overwrite() async {
        guard let doc = await model.reloadNotes() else {
            problem = "Couldn't reach the hub."
            return
        }
        conflict = false
        baseRev = doc.rev
        await save(rev: doc.rev)
    }
}

/// The preview: the same lines the panel draws, read-only.
private struct NotesPreview: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(NotesText.lines(text).enumerated()), id: \.offset) { _, line in
                switch line {
                case let .heading(level, t):
                    Text(LimitedMarkdown.render(t)).font(.system(size: level <= 1 ? 15 : 13, weight: .semibold))
                case let .checkbox(_, checked, t, indent):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: checked ? "checkmark.square.fill" : "square").foregroundStyle(.secondary)
                        Text(LimitedMarkdown.render(t)).strikethrough(checked).opacity(checked ? 0.5 : 1)
                    }
                    .padding(.leading, CGFloat(indent) * 14)
                case let .bullet(t, indent):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(.secondary)
                        Text(LimitedMarkdown.render(t))
                    }
                    .padding(.leading, CGFloat(indent) * 14)
                case let .text(t):
                    Text(LimitedMarkdown.render(t))
                case .blank:
                    Spacer().frame(height: 2)
                }
            }
        }
        .font(.system(size: 13))
        // Links in the preview don't open from here: it's for checking the text.
        .environment(\.openURL, OpenURLAction { _ in .discarded })
    }
}
