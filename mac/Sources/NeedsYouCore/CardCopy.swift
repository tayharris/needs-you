import Foundation

// Copying from a card. The panel is never key (FloatingPanel), so a card's text can't be
// selected; instead a card offers its commands as copy chips and the "…" menu copies the
// title and text, the link URLs and, in Developer mode, the item itself (JSON, a debug
// report, a `needs-you add` command that re-creates it).
//
// Nothing copied carries a secret: the item holds no tokens, the app passes in no hub
// URL with credentials, and `redactSecrets` masks anything shaped like a token, peer
// secret or invite code that a sender put in the text anyway (rule 3; same patterns as
// the hub's log redaction).

/// What a card can copy, and the text of each copy.
public enum CardCopy {
    /// At most this many command chips per card.
    public static let maxSnippets = 4
    /// Longer snippets aren't offered: a chip shows its whole snippet, wrapped, so what
    /// the person reads is exactly what's copied.
    public static let maxSnippetLength = 200

    // MARK: - Command snippets

    /// The commands, paths and ids worth a copy chip, in body order: one-line fenced code
    /// blocks, and inline code spans that look like a command (several words), a path or an
    /// id (`term_4170demo`, `ACME-123`). Single plain words (`claude`, `prod`, `74511`) are
    /// left as text. Deduplicated, at most `maxSnippets`.
    ///
    /// Card text is untrusted (any sender wrote it) and a chip's text may be pasted into a
    /// terminal, so a chip copies exactly what it shows, and nothing that could hide
    /// something is offered (`isSafeSnippet`): no line breaks (so no multi-line blocks), no
    /// control, bidi, zero-width or other invisible format characters, at most
    /// `maxSnippetLength` characters, and nothing `redactSecrets` would change.
    public static func snippets(in body: String?) -> [String] {
        guard let body, !body.isEmpty else { return [] }
        let text = String(body.prefix(LimitedMarkdown.maxLength))
        var found: [String] = []
        func add(_ raw: String, fenced: Bool) {
            let s = raw.trimmingCharacters(in: .whitespaces)
            guard isSafeSnippet(s), fenced || looksCopyable(s),
                  !found.contains(s), found.count < maxSnippets else { return }
            found.append(s)
        }
        for chunk in chunks(text) {
            switch chunk {
            case .fence(let code): add(code, fenced: true)
            case .prose(let prose): for span in inlineCodeSpans(prose) { add(span, fenced: false) }
            }
        }
        return found
    }

    enum Chunk: Equatable {
        case prose(String)
        case fence(String)
    }

    /// The body split into prose and fenced code blocks (``` or ~~~, at most 3 spaces of
    /// indent; the info string after the opening fence is dropped). An unclosed fence runs
    /// to the end, as in CommonMark.
    static func chunks(_ text: String) -> [Chunk] {
        var out: [Chunk] = []
        var prose: [String] = []
        var code: [String] = []
        var fence: (char: Character, count: Int)?
        func flushProse() {
            if !prose.isEmpty { out.append(.prose(prose.joined(separator: "\n"))) }
            prose = []
        }
        for line in text.components(separatedBy: "\n") {
            let indent = line.prefix(while: { $0 == " " }).count
            let rest = line.dropFirst(indent)
            if let open = fence {
                let run = rest.prefix(while: { $0 == open.char }).count
                if indent < 4, run >= open.count, rest.dropFirst(run).allSatisfy({ $0 == " " || $0 == "\t" }) {
                    out.append(.fence(code.joined(separator: "\n")))
                    code = []
                    fence = nil
                } else {
                    code.append(line)
                }
                continue
            }
            if indent < 4, let c = rest.first, c == "`" || c == "~" {
                let run = rest.prefix(while: { $0 == c }).count
                // A backtick fence's info string can't hold a backtick (that's inline code).
                if run >= 3, c == "~" || !rest.dropFirst(run).contains("`") {
                    flushProse()
                    fence = (c, run)
                    continue
                }
            }
            prose.append(line)
        }
        if fence != nil { out.append(.fence(code.joined(separator: "\n"))) }
        flushProse()
        return out
    }

    /// Inline code spans (CommonMark): a run of N backticks up to the next run of exactly
    /// N; line breaks inside become spaces, and one space each side is dropped when both
    /// are there. An unmatched run is literal text.
    static func inlineCodeSpans(_ text: String) -> [String] {
        let chars = Array(text)
        var spans: [String] = []
        var i = 0
        while i < chars.count {
            guard chars[i] == "`" else { i += 1; continue }
            var n = 0
            while i + n < chars.count, chars[i + n] == "`" { n += 1 }
            // Look for a closing run of exactly n.
            var j = i + n
            var closeAt: Int?
            while j < chars.count {
                if chars[j] == "`" {
                    var m = 0
                    while j + m < chars.count, chars[j + m] == "`" { m += 1 }
                    if m == n { closeAt = j; break }
                    j += m
                } else {
                    j += 1
                }
            }
            guard let close = closeAt else { i += n; continue }
            var content = String(chars[(i + n)..<close]).replacingOccurrences(of: "\n", with: " ")
            if content.count >= 2, content.hasPrefix(" "), content.hasSuffix(" "),
               content.contains(where: { $0 != " " }) {
                content = String(content.dropFirst().dropLast())
            }
            spans.append(content)
            i = close + n
        }
        return spans
    }

    /// A chip may offer it: not empty, at most `maxSnippetLength` characters, one line, no
    /// control (tab, CR, NUL, escape...), format (bidi overrides and isolates, zero-width
    /// characters, soft hyphen, BOM) or line/paragraph separator characters, and no
    /// token-shaped text (a copy would have to differ from what the card shows).
    public static func isSafeSnippet(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= maxSnippetLength else { return false }
        if s.unicodeScalars.contains(where: isHiddenOrControl) { return false }
        return redactSecrets(s) == s
    }

    /// Control, format and line/paragraph separator scalars: what can make text read
    /// differently from what it is, or run on past what's visible.
    public static func isHiddenOrControl(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .privateUse, .unassigned:
            return true
        default:
            return false
        }
    }

    /// A command (two or more words), a path (`/srv/photos`, `~/orca/acme`) or an id (eight
    /// or more characters with a digit or punctuation: `term_4170demo`, `ACME-123`). Plain
    /// words and short numbers stay text.
    static func looksCopyable(_ s: String) -> Bool {
        if s.contains(where: { $0.isWhitespace }) { return s.count >= 5 }
        if s.contains("/") || s.hasPrefix("~") { return s.count >= 5 }
        return s.count >= 8 && s.contains(where: { $0.isNumber || "_-.:@=#".contains($0) })
    }

    // MARK: - The "…" menu

    /// "Copy Title and Text": the title, the body as plain text (markdown rendered the way
    /// the card shows it), and the steps numbered.
    public static func titleAndText(_ item: Item) -> String {
        var parts = [item.title]
        if let body = item.body?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty {
            parts.append(LimitedMarkdown.plainText(body))
        }
        if !item.steps.isEmpty {
            parts.append(item.steps.enumerated().map { index, step in
                "\(index + 1). " + LimitedMarkdown.plainText(step.text)
            }.joined(separator: "\n"))
        }
        return redactSecrets(parts.joined(separator: "\n\n"))
    }

    /// "Copy Link URLs": each link's URL on its own line; nil without links.
    public static func linkURLs(_ item: Item) -> String? {
        let urls = item.links.map(\.url).filter { !$0.isEmpty }
        return urls.isEmpty ? nil : redactSecrets(urls.joined(separator: "\n"))
    }

    // MARK: - Developer mode

    /// The whole item as pretty JSON: the hub's field names, sorted keys, ISO 8601 dates. The
    /// priority is the sender's, as the hub has it, not a bypass rule's.
    public static func itemJSON(_ item: Item) -> String {
        var item = item
        item.priority = item.senderPriority ?? item.priority
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(HubJSON.formatDate(date))
        }
        guard let data = try? encoder.encode(item), let text = String(data: data, encoding: .utf8) else { return "{}" }
        return redactSecrets(text)
    }

    /// What the debug report says besides the item. The app fills it in; none of it is a
    /// token, peer secret or invite code (the feed is a hub's short name, never its token).
    public struct DebugInfo: Equatable, Sendable {
        public var appVersion: String
        public var osVersion: String
        /// The hub the last successful poll came from ("This Mac", "hub2"), or "demo".
        public var feed: String?
        /// The delivery tier the item would get now, and why.
        public var delivery: DeliveryDecision?
        /// The first bypass rule that matches the item, if any.
        public var rule: BypassRule?
        /// The focus in force ("Off", "Urgent only").
        public var focus: String?
        public var capturedAt: Date

        public init(appVersion: String, osVersion: String, feed: String? = nil, delivery: DeliveryDecision? = nil,
                    rule: BypassRule? = nil, focus: String? = nil, capturedAt: Date = Date()) {
            self.appVersion = appVersion
            self.osVersion = osVersion
            self.feed = feed
            self.delivery = delivery
            self.rule = rule
            self.focus = focus
            self.capturedAt = capturedAt
        }
    }

    /// "Copy Debug Report": Markdown for a bug report: the app and macOS versions, where
    /// the item came from, how it's delivered, then the item JSON in a fenced block.
    public static func debugReport(_ item: Item, info: DebugInfo) -> String {
        var lines = ["## Needs You debug report", ""]
        lines.append("- App: Needs You \(info.appVersion)")
        lines.append("- macOS: \(info.osVersion)")
        if let feed = info.feed { lines.append("- Feed: \(feed)") }
        if let d = info.delivery {
            lines.append("- Delivery now: \(d.tier.title) (\(d.reason.rawValue))\(d.holdsForLater ? ", held for Later" : "")")
        }
        if let rule = info.rule {
            lines.append("- Bypass rule: \(rule.match.title) \u{201C}\(rule.value)\u{201D} \u{2192} \(rule.action.title)")
        } else {
            lines.append("- Bypass rule: none")
        }
        if let focus = info.focus { lines.append("- Focus: \(focus)") }
        lines.append("- Captured: \(HubJSON.formatDate(info.capturedAt))")
        let json = itemJSON(item)
        let fence = String(repeating: "`", count: max(3, longestBacktickRun(json) + 1))
        lines += ["", "### Item", "", fence + "json", json, fence, ""]
        return redactSecrets(lines.joined(separator: "\n"))
    }

    static func longestBacktickRun(_ s: String) -> Int {
        var best = 0, run = 0
        for c in s {
            run = c == "`" ? run + 1 : 0
            best = max(best, run)
        }
        return best
    }

    /// "Copy as needs-you add Command": a one-line `needs-you add` command that posts the
    /// same card again (key, title, body, context, priority, kind, links, steps, question,
    /// source), for reproducing a bug. The expiry isn't carried (it was relative to the
    /// first post).
    ///
    /// Every value is untrusted (a sender wrote it), so the line must be inert when pasted:
    /// each value is redacted, then cleaned (`shellSafeValue`: no control, bidi, zero-width
    /// or other format characters), then quoted (`shellQuote`) as `--flag=value`, so a
    /// value starting with "-" isn't read as a flag. Line breaks are kept only inside
    /// `$'…'` as `\n`, so the command is always one line: nothing runs until Return.
    public static func addCommand(_ item: Item) -> String {
        var args: [String] = ["needs-you", "add"]
        func flag(_ name: String, _ value: String?) {
            guard let value else { return }
            args.append("--\(name)=" + shellQuote(shellSafeValue(redactSecrets(value))))
        }
        flag("key", item.key)
        flag("title", item.title)
        if let body = item.body, !body.isEmpty { flag("body", body) }
        flag("context", item.context.rawValue)
        flag("priority", (item.senderPriority ?? item.priority).rawValue)
        if item.kind != .needs { flag("kind", item.kind.rawValue) }
        for link in item.links { flag("link", linkArgument(link)) }
        if !item.steps.isEmpty { flag("steps-json", compactJSON(item.steps)) }
        if var question = item.question {
            question.expiresAt = nil
            flag("question-json", compactJSON(question))
        }
        if let source = item.source {
            if let agent = source.agent, !agent.isEmpty { flag("agent", agent) }
            if let project = source.project, !project.isEmpty { flag("project", project) }
            if let host = source.host, !host.isEmpty { flag("host", host) }
            if let event = source.event, !event.isEmpty { flag("event", event) }
        }
        return args.joined(separator: " ")
    }

    /// A value cleaned for the command line: line and paragraph separators and CR/LF pairs
    /// become "\n", tabs stay, and every other control or invisible format character
    /// (NUL, escape, bidi overrides, zero-width characters, BOM) is dropped.
    public static func shellSafeValue(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        var lastWasCR = false
        for scalar in s.unicodeScalars {
            defer { lastWasCR = scalar == "\r" }
            switch scalar {
            case "\n":
                if !lastWasCR { out.append("\n") }
            case "\r", "\u{2028}", "\u{2029}", "\u{85}":
                out.append("\n")
            case "\t":
                out.append(scalar)
            default:
                if !isHiddenOrControl(scalar) { out.append(scalar) }
            }
        }
        return String(out)
    }

    /// The CLI's `LABEL=URL`. `parse_link` splits at the first "=" and reads the whole
    /// argument as a bare URL when the left side is empty or holds "://", so the label is
    /// always given and never holds "=": "=" becomes "-", control and format characters
    /// are dropped, and a label left empty or holding "://" is "Link" (the CLI's own name
    /// for a bare URL). The first "=" is then always the separator, whatever the URL holds.
    public static func linkArgument(_ link: ItemLink) -> String {
        var label = String(String.UnicodeScalarView(link.label.unicodeScalars.filter { !isHiddenOrControl($0) }))
        label = label.replacingOccurrences(of: "=", with: "-").trimmingCharacters(in: .whitespaces)
        if label.isEmpty || label.contains("://") { label = "Link" }
        return label + "=" + link.url
    }

    static func compactJSON<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(HubJSON.formatDate(date))
        }
        guard let data = try? encoder.encode(value), let s = String(data: data, encoding: .utf8) else { return "null" }
        return s
    }

    /// Shell quoting for a cleaned value (`shellSafeValue`): plain words as they are;
    /// otherwise single quotes, with a single quote inside written '"'"' (nothing is special
    /// inside single quotes in sh, bash or zsh). A value with a line break or tab uses
    /// ANSI-C quoting, $'…' (bash and zsh), with only \\, \', \n and \t escaped, so the
    /// command stays on one line. Any other control character is dropped.
    public static func shellQuote(_ s: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+=:,./_-")
        if !s.isEmpty, s.unicodeScalars.allSatisfy({ safe.contains($0) }) { return s }
        if !s.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
            return "'" + s.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        }
        var out = "$'"
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "'": out += "\\'"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            default:
                // Any other control character is dropped, never passed through.
                if scalar.properties.generalCategory != .control { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "'"
    }

    // MARK: - Secrets

    private static let secretPatterns: [(NSRegularExpression, String)] = {
        let word = "(?:\\b|(?<=%[0-9A-Fa-f]{2}))"
        let table: [(String, String)] = [
            ("/join/[^/\\s\"?#]+", "/join/<code>"),
            (word + "nyi_[A-Za-z0-9_\\-]+", "nyi_<redacted>"),
            (word + "ny_[A-Za-z0-9_\\-]{16,}", "ny_<redacted>"),
            (word + "nyp_[A-Za-z0-9_\\-]+", "nyp_<redacted>"),
        ]
        return table.compactMap { pattern, replacement in
            (try? NSRegularExpression(pattern: pattern)).map { ($0, replacement) }
        }
    }()

    /// Masks invite codes (`nyi_…`, `/join/<code>`), tokens (`ny_…`) and peer secrets
    /// (`nyp_…`), the hub's log redaction patterns. Senders must never put these in an
    /// item; this keeps a copy from carrying one if they did.
    public static func redactSecrets(_ text: String) -> String {
        var out = text
        for (regex, replacement) in secretPatterns {
            let range = NSRange(out.startIndex..., in: out)
            out = regex.stringByReplacingMatches(in: out, range: range,
                                                 withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
        }
        return out
    }
}
