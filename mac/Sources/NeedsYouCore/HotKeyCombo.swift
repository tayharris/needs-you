import Foundation

/// A global shortcut: a virtual key code plus Carbon modifier flags, as RegisterEventHotKey
/// takes them. Stored in UserDefaults as readable text ("control+option+space") and shown
/// with the usual symbols ("⌃⌥Space").
///
/// Key codes are the `kVK_*` values from Carbon's Events.h and the modifier bits are
/// Carbon's (`cmdKey`, `shiftKey`, `optionKey`, `controlKey`). Core doesn't import Carbon,
/// so they're spelled out here.
public struct HotKeyCombo: Equatable, Hashable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers & Self.allModifiers
    }

    // Carbon modifier bits.
    public static let command: UInt32 = 1 << 8   // cmdKey
    public static let shift: UInt32 = 1 << 9     // shiftKey
    public static let option: UInt32 = 1 << 11   // optionKey
    public static let control: UInt32 = 1 << 12  // controlKey
    public static let allModifiers = command | shift | option | control

    /// ⌃⌥Space, the original shortcut.
    public static let standard = HotKeyCombo(keyCode: KeyNames.space, modifiers: control | option)

    /// "⌃⌥⇧⌘K" in Apple's modifier order.
    public var display: String {
        var s = ""
        if modifiers & Self.control != 0 { s += "⌃" }
        if modifiers & Self.option != 0 { s += "⌥" }
        if modifiers & Self.shift != 0 { s += "⇧" }
        if modifiers & Self.command != 0 { s += "⌘" }
        return s + (KeyNames.display(keyCode) ?? "Key \(keyCode)")
    }

    /// The character a menu item shows as this shortcut's hint ("k", " "), or nil.
    public var menuKeyEquivalent: String? { KeyNames.menuCharacter(keyCode) }

    /// "control+option+space": what's stored in UserDefaults.
    public var storageString: String {
        var parts: [String] = []
        if modifiers & Self.control != 0 { parts.append("control") }
        if modifiers & Self.option != 0 { parts.append("option") }
        if modifiers & Self.shift != 0 { parts.append("shift") }
        if modifiers & Self.command != 0 { parts.append("command") }
        parts.append(KeyNames.token(keyCode) ?? "code\(keyCode)")
        return parts.joined(separator: "+")
    }

    /// Parses `storageString` (and friendly spellings: "ctrl+opt+space", "cmd+shift+k",
    /// "⌃⌥Space"). nil when it names no key or an unknown one.
    public static func parse(_ text: String) -> HotKeyCombo? {
        var rest = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rest.isEmpty else { return nil }
        var mods: UInt32 = 0
        // Leading symbols: ⌃⌥⇧⌘.
        let symbols: [Character: UInt32] = ["⌃": control, "⌥": option, "⇧": shift, "⌘": command]
        while let first = rest.first, let bit = symbols[first] {
            mods |= bit
            rest.removeFirst()
        }
        let parts = rest.lowercased().split(separator: "+", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard let keyPart = parts.last, !keyPart.isEmpty else { return nil }
        for p in parts.dropLast() {
            switch p {
            case "control", "ctrl", "ctl": mods |= control
            case "option", "opt", "alt": mods |= option
            case "shift": mods |= shift
            case "command", "cmd": mods |= command
            default: return nil
            }
        }
        let code: UInt32
        if keyPart.hasPrefix("code"), let n = UInt32(keyPart.dropFirst(4)) {
            code = n
        } else if let known = KeyNames.code(forToken: keyPart) {
            code = known
        } else {
            return nil
        }
        guard KeyNames.display(code) != nil else { return nil }
        return HotKeyCombo(keyCode: code, modifiers: mods)
    }
}

/// Why a shortcut can't be used.
public enum HotKeyProblem: Equatable, Sendable {
    /// Needs ⌃, ⌥ or ⌘ (⇧ alone isn't enough: it would eat typing).
    case needsModifier
    /// A key this app can't name (or Escape, which closes the panel).
    case unsupportedKey
    /// macOS or every app already uses it.
    case reserved(String)

    public var message: String {
        switch self {
        case .needsModifier: return "Add ⌃, ⌥ or ⌘ so the shortcut doesn't get in the way of typing."
        case .unsupportedKey: return "That key can't be used for the shortcut."
        case .reserved(let what): return "That's \(what). Pick another shortcut."
        }
    }
}

public enum HotKeyValidator {
    /// Shortcuts macOS or nearly every app owns.
    public static let reserved: [HotKeyCombo: String] = {
        let c = HotKeyCombo.command, s = HotKeyCombo.shift, o = HotKeyCombo.option, k = HotKeyCombo.control
        var r: [HotKeyCombo: String] = [:]
        func add(_ key: UInt32, _ mods: UInt32, _ what: String) { r[HotKeyCombo(keyCode: key, modifiers: mods)] = what }
        add(KeyNames.space, c, "Spotlight")
        add(KeyNames.space, c | o, "Finder search")
        add(KeyNames.space, k, "input source switching")
        add(KeyNames.space, k | c, "the emoji picker")
        add(KeyNames.tab, c, "the app switcher")
        add(KeyNames.tab, c | s, "the app switcher")
        add(KeyNames.grave, c, "window switching")
        add(KeyNames.letter("q")!, c, "Quit in every app")
        add(KeyNames.letter("w")!, c, "Close Window in every app")
        add(KeyNames.letter("h")!, c, "Hide in every app")
        add(KeyNames.letter("m")!, c, "Minimize in every app")
        add(KeyNames.letter("q")!, c | k, "Lock Screen")
        add(KeyNames.escape, c | o, "Force Quit")
        add(KeyNames.digit(3)!, c | s, "a screenshot shortcut")
        add(KeyNames.digit(4)!, c | s, "a screenshot shortcut")
        add(KeyNames.digit(5)!, c | s, "a screenshot shortcut")
        add(KeyNames.letter("c")!, c, "Copy in every app")
        add(KeyNames.letter("v")!, c, "Paste in every app")
        add(KeyNames.letter("x")!, c, "Cut in every app")
        add(KeyNames.letter("z")!, c, "Undo in every app")
        add(KeyNames.letter("a")!, c, "Select All in every app")
        return r
    }()

    /// nil when `combo` can be registered.
    public static func problem(with combo: HotKeyCombo) -> HotKeyProblem? {
        guard KeyNames.display(combo.keyCode) != nil, combo.keyCode != KeyNames.escape || combo.modifiers != 0 else {
            return .unsupportedKey
        }
        let needed = HotKeyCombo.control | HotKeyCombo.option | HotKeyCombo.command
        if combo.modifiers & needed == 0 { return .needsModifier }
        if let what = reserved[combo] { return .reserved(what) }
        return nil
    }

    public static func isValid(_ combo: HotKeyCombo) -> Bool { problem(with: combo) == nil }

    /// The stored shortcut, or ⌃⌥Space when it's missing, unreadable or no longer valid.
    public static func stored(_ text: String?) -> HotKeyCombo {
        guard let text, let combo = HotKeyCombo.parse(text), isValid(combo) else { return .standard }
        return combo
    }
}

/// Names for the virtual key codes a shortcut may use (US layout positions, like the
/// menu bar shows them).
public enum KeyNames {
    public static let space: UInt32 = 0x31
    public static let tab: UInt32 = 0x30
    public static let returnKey: UInt32 = 0x24
    public static let escape: UInt32 = 0x35
    public static let delete: UInt32 = 0x33
    public static let grave: UInt32 = 0x32

    private static let letters: [(String, UInt32)] = [
        ("a", 0x00), ("s", 0x01), ("d", 0x02), ("f", 0x03), ("h", 0x04), ("g", 0x05), ("z", 0x06),
        ("x", 0x07), ("c", 0x08), ("v", 0x09), ("b", 0x0B), ("q", 0x0C), ("w", 0x0D), ("e", 0x0E),
        ("r", 0x0F), ("y", 0x10), ("t", 0x11), ("o", 0x1F), ("u", 0x20), ("i", 0x22), ("p", 0x23),
        ("l", 0x25), ("j", 0x26), ("k", 0x28), ("n", 0x2D), ("m", 0x2E),
    ]
    private static let digits: [(Int, UInt32)] = [
        (1, 0x12), (2, 0x13), (3, 0x14), (4, 0x15), (6, 0x16), (5, 0x17), (9, 0x19), (7, 0x1A), (8, 0x1C), (0, 0x1D),
    ]
    /// token, display, code
    private static let others: [(String, String, UInt32)] = [
        ("space", "Space", space), ("tab", "Tab", tab), ("return", "Return", returnKey),
        ("escape", "Esc", escape), ("delete", "Delete", delete), ("forwarddelete", "⌦", 0x75),
        ("grave", "`", grave), ("minus", "-", 0x1B), ("equal", "=", 0x18),
        ("leftbracket", "[", 0x21), ("rightbracket", "]", 0x1E), ("backslash", "\\", 0x2A),
        ("semicolon", ";", 0x29), ("quote", "'", 0x27), ("comma", ",", 0x2B), ("period", ".", 0x2F),
        ("slash", "/", 0x2C),
        ("left", "←", 0x7B), ("right", "→", 0x7C), ("down", "↓", 0x7D), ("up", "↑", 0x7E),
        ("home", "↖", 0x73), ("end", "↘", 0x77), ("pageup", "⇞", 0x74), ("pagedown", "⇟", 0x79),
        ("f1", "F1", 0x7A), ("f2", "F2", 0x78), ("f3", "F3", 0x63), ("f4", "F4", 0x76),
        ("f5", "F5", 0x60), ("f6", "F6", 0x61), ("f7", "F7", 0x62), ("f8", "F8", 0x64),
        ("f9", "F9", 0x65), ("f10", "F10", 0x6D), ("f11", "F11", 0x67), ("f12", "F12", 0x6F),
        ("f13", "F13", 0x69), ("f14", "F14", 0x6B), ("f15", "F15", 0x71), ("f16", "F16", 0x6A),
        ("f17", "F17", 0x40), ("f18", "F18", 0x4F), ("f19", "F19", 0x50), ("f20", "F20", 0x5A),
    ]

    private static let table: [UInt32: (token: String, display: String)] = {
        var t: [UInt32: (token: String, display: String)] = [:]
        for (name, code) in letters { t[code] = (name, name.uppercased()) }
        for (n, code) in digits { t[code] = (String(n), String(n)) }
        for (token, display, code) in others { t[code] = (token, display) }
        return t
    }()

    private static let byToken: [String: UInt32] = {
        var m: [String: UInt32] = [:]
        for (code, names) in table {
            m[names.token] = code
            m[names.display.lowercased()] = code
        }
        m["esc"] = escape
        m["enter"] = returnKey
        m["backtick"] = grave
        return m
    }()

    public static func display(_ code: UInt32) -> String? { table[code]?.display }

    /// Letters, digits, space and punctuation as a menu key equivalent; nil for the rest.
    public static func menuCharacter(_ code: UInt32) -> String? {
        if code == space { return " " }
        guard let names = table[code] else { return nil }
        if names.token.count == 1 { return names.token }        // a-z, 0-9
        if names.display.count == 1, !names.token.hasPrefix("f"), names.display.unicodeScalars.allSatisfy({ $0.isASCII }) {
            return names.display                                // ` - = [ ] \ ; ' , . /
        }
        return nil
    }
    public static func token(_ code: UInt32) -> String? { table[code]?.token }
    public static func code(forToken token: String) -> UInt32? { byToken[token.lowercased()] }
    public static func letter(_ l: String) -> UInt32? { letters.first { $0.0 == l.lowercased() }?.1 }
    public static func digit(_ d: Int) -> UInt32? { digits.first { $0.0 == d }?.1 }
}

/// What the global shortcut does.
public enum HotKeyAction: Equatable, Sendable {
    /// Show or hide the floating panel (the original).
    case toggleVisibility
    /// Open the top card's first allowed link (the Orca terminal jump, a VS Code window...).
    case openTopCard(Item)

    /// "Hotkey also opens the top card's first link" (off by default): with it on and
    /// something waiting that has an allowed link, the shortcut opens it instead of showing
    /// or hiding the panel. `top` is the first card in panel order (urgent first, oldest).
    public static func decide(openTopLink: Bool, top: Item?) -> HotKeyAction {
        guard openTopLink, let top, top.kind == .needs, top.status == .open,
              case .open = MenuItemAction.forItem(top) else { return .toggleVisibility }
        return .openTopCard(top)
    }
}
