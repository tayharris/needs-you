import Foundation

/// The card body renderer: bold, italic, code, simple lists and allow-listed links.
/// No HTML, no images (PLAN.md, "Cards").
public enum LimitedMarkdown {
    public static let maxLength = 2_000

    public static func render(_ source: String) -> AttributedString {
        var text = stripBidiControls(String(source.prefix(maxLength)))
        text = bulletise(text)

        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard var attributed = try? AttributedString(markdown: text, options: options) else {
            return AttributedString(text)
        }

        // Strip images and any link whose scheme isn't allowed; the text stays as plain text.
        for run in attributed.runs {
            if run.imageURL != nil {
                attributed[run.range].imageURL = nil
            }
            if let link = run.link, !LinkPolicy.isAllowed(link) {
                attributed[run.range].link = nil
            }
        }
        return attributed
    }

    /// Removes bidi embedding, override and isolate controls (U+202A to U+202E, U+2066 to
    /// U+2069). They let text read differently from what it is (a reversed "moc.live" shows
    /// as "evil.com"); ordinary right-to-left text doesn't need them. The hub refuses them in
    /// new items; this covers anything older or replicated.
    public static func stripBidiControls(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: isBidiControl) else { return text }
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: text.unicodeScalars.filter { !isBidiControl($0) })
        return String(scalars)
    }

    static func isBidiControl(_ s: Unicode.Scalar) -> Bool {
        (0x202A...0x202E).contains(s.value) || (0x2066...0x2069).contains(s.value)
    }

    /// Inline-only parsing keeps list markers as literal text; make them read as bullets.
    static func bulletise(_ text: String) -> String {
        text
            .components(separatedBy: "\n")
            .map { line -> String in
                let indent = line.prefix(while: { $0 == " " })
                let rest = line.dropFirst(indent.count)
                if rest.hasPrefix("- ") || rest.hasPrefix("* ") || rest.hasPrefix("+ ") {
                    return indent + "• " + rest.dropFirst(2)
                }
                return line
            }
            .joined(separator: "\n")
    }

    /// Plain-text fallback (used for previews and accessibility).
    public static func plainText(_ source: String) -> String {
        String(render(source).characters)
    }
}
