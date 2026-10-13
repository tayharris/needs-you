import NeedsYouCore
import SwiftUI

/// The open panel's Notes (ADR 0014): the person's own short list beside the alerts.
/// Headings, checkboxes, bullets and text, drawn with the card renderer (allow-listed links
/// only). A checkbox is a plain button, like a card's steps: the panel never becomes key, so
/// clicking it never takes focus. Typing happens in the notes window (Edit).
struct NotesList: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: model.metrics.cardRowSpacing + 2) {
            if let problem = model.notesProblem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(Theme.meta(model.metrics))
                    .foregroundStyle(Theme.urgent.opacity(0.85))
                    .lineLimit(3)
            }
            if let notes = model.notes {
                let lines = NotesText.lines(notes.text)
                if lines.isEmpty {
                    NotesEmpty(model: model)
                } else {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        NotesLineView(line: line, model: model)
                    }
                }
                HStack {
                    Spacer()
                    Button { model.openNotesWindow() } label: {
                        Label("Edit…", systemImage: "square.and.pencil")
                            .font(.system(size: model.metrics.actionFont, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Edit the notes in their own window (markdown)")
                }
                .padding(.top, 4)
            } else {
                Text(model.lastError == nil ? "Notes need a hub with needs-you 0.6.0 or later."
                                            : "Notes show once the hub answers.")
                    .font(Theme.body(model.bodyFont))
                    .foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct NotesEmpty: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "checklist")
                .font(.system(size: 18))
                .foregroundStyle(Theme.muted)
            Text("No notes yet")
                .font(Theme.body(model.bodyFont))
                .foregroundStyle(Theme.text.opacity(0.8))
            Text("Edit to add a few things to do. Agents can add lines with `needs-you notes add`.")
                .font(Theme.meta(model.metrics))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }
}

private struct NotesLineView: View {
    let line: NotesText.Line
    @ObservedObject var model: AppModel

    var body: some View {
        let font = model.bodyFont
        switch line {
        case let .heading(level, text):
            Text(LimitedMarkdown.render(text))
                .font(.system(size: level <= 1 ? model.metrics.headerFont : model.metrics.sectionFont + 1, weight: .semibold))
                .foregroundStyle(level <= 2 ? Theme.text.opacity(0.9) : Theme.muted)
                .tint(Theme.accent)
                .padding(.top, 2)
                .fixedSize(horizontal: false, vertical: true)
        case let .checkbox(index, checked, text, indent):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Button { model.toggleNoteCheckbox(index: index, text: text, checked: checked) } label: {
                    Image(systemName: checked ? "checkmark.square.fill" : "square")
                        .font(.system(size: font))
                        .foregroundStyle(checked ? Theme.accent.opacity(0.9) : Theme.muted)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(checked ? "Untick" : "Tick off")
                Text(LimitedMarkdown.render(text))
                    .strikethrough(checked, color: Theme.text.opacity(0.35))
                    .font(Theme.body(font))
                    .foregroundStyle(Theme.text.opacity(checked ? 0.45 : 0.85))
                    .tint(Theme.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(indent) * 14)
        case let .bullet(text, indent):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•").font(Theme.body(font)).foregroundStyle(Theme.muted)
                Text(LimitedMarkdown.render(text))
                    .font(Theme.body(font))
                    .foregroundStyle(Theme.text.opacity(0.85))
                    .tint(Theme.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(indent) * 14 + 2)
        case let .text(text):
            Text(LimitedMarkdown.render(text))
                .font(Theme.body(font))
                .foregroundStyle(Theme.text.opacity(0.8))
                .tint(Theme.accent)
                .fixedSize(horizontal: false, vertical: true)
        case .blank:
            Spacer().frame(height: 2)
        }
    }
}
