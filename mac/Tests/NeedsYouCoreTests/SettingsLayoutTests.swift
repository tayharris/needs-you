#if NEEDSYOU_SELFTEST
import MiniXCTest
#else
import XCTest
#endif
import Foundation
import NeedsYouCore

/// The Settings layout rule (SettingsLayout.swift): look settings only under Appearance,
/// behaviour settings never there, every stored key placed, and every Settings section in
/// the app writing only keys registered to its own page.
final class SettingsLayoutTests: XCTestCase {
    static var allTests = [
        ("testLookOnlyUnderAppearance", testLookOnlyUnderAppearance),
        ("testKeysAndPathsAreUnique", testKeysAndPathsAreUnique),
        ("testEveryUIPrefsKeyIsRegistered", testEveryUIPrefsKeyIsRegistered),
        ("testEveryOtherSettingsKeyIsRegistered", testEveryOtherSettingsKeyIsRegistered),
        ("testEveryPageHasSections", testEveryPageHasSections),
        ("testSectionsWriteOnlyTheirPagesKeys", testSectionsWriteOnlyTheirPagesKeys),
        ("testMovedSettingsAndOldNames", testMovedSettingsAndOldNames),
        ("testAppearanceResetResetsLookOnly", testAppearanceResetResetsLookOnly),
    ]

    private let suite = TestDefaults.suiteName(SettingsLayoutTests.self)
    private let emptySuite = TestDefaults.suiteName(SettingsLayoutTests.self) + ".empty"

    override func tearDown() {
        TestDefaults.clear(suite)
        TestDefaults.clear(emptySuite)
        super.tearDown()
    }

    /// Walks every page: a look setting on a page outside Appearance, or a behaviour setting
    /// on an Appearance page, fails.
    func testLookOnlyUnderAppearance() {
        for tab in SettingsTab.allCases {
            for key in SettingsRegistry.keys(on: tab) {
                let placement = SettingsRegistry.placement(forKey: key)!
                switch placement.kind {
                case .look:
                    XCTAssertEqual(tab.group, .appearance, "look setting \(key) is on \(tab.title), outside Appearance")
                case .behaviour:
                    XCTAssertNotEqual(tab.group, .appearance, "behaviour setting \(key) is on Appearance → \(tab.title)")
                }
            }
        }
        // The rule isn't vacuous: there are look settings on every Appearance page.
        for tab in SettingsSidebarGroup.appearance.pages(canInvite: true) {
            XCTAssertFalse(SettingsRegistry.keys(on: tab).isEmpty, "\(tab.title) shows no setting")
        }
    }

    func testKeysAndPathsAreUnique() {
        let keys = SettingsRegistry.all.map(\.key)
        XCTAssertEqual(Set(keys).count, keys.count, "a key is registered twice")
        let paths = SettingsRegistry.all.map(\.path)
        XCTAssertEqual(Set(paths).count, paths.count, "a path is registered twice")
        for key in SettingsRegistry.unlisted.keys {
            XCTAssertNil(SettingsRegistry.placement(forKey: key), "\(key) is both registered and unlisted")
        }
    }

    /// The keys a value type's `save` writes: what's in the suite after saving, less what an
    /// untouched suite already shows (the global domain).
    private func savedKeys(_ save: (UserDefaults) -> Void) -> Set<String> {
        let empty = Set(TestDefaults.make(emptySuite).dictionaryRepresentation().keys)
        let store = TestDefaults.make(suite)
        save(store)
        return Set(store.dictionaryRepresentation().keys).subtracting(empty)
    }

    private func assertPlaced(_ keys: Set<String>, _ owner: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(keys.isEmpty, "\(owner): no keys found", file: file, line: line)
        for key in keys.sorted() {
            XCTAssertTrue(SettingsRegistry.placement(forKey: key) != nil || SettingsRegistry.unlisted[key] != nil,
                          "\(owner) key \(key) has no line in SettingsRegistry.all (or .unlisted)", file: file, line: line)
        }
    }

    /// Every UIPrefs key (whatever `save` writes, so a new key can't be missed) is placed on
    /// a page.
    func testEveryUIPrefsKeyIsRegistered() {
        let keys = savedKeys { UIPrefs().save(to: $0) }
        XCTAssertTrue(keys.count >= 26, "UIPrefs.save wrote only \(keys.sorted())")
        for key in keys.sorted() {
            XCTAssertNotNil(SettingsRegistry.placement(forKey: key), "UIPrefs key \(key) has no line in SettingsRegistry.all")
        }
    }

    func testEveryOtherSettingsKeyIsRegistered() {
        assertPlaced(savedKeys { UsagePrefs().save(to: $0) }, "UsagePrefs")
        assertPlaced(savedKeys { DeliveryDefaults().save(to: $0) }, "DeliveryDefaults")
        assertPlaced(savedKeys { UpdatePrefs().save(to: $0) }, "UpdatePrefs")
        assertPlaced(Set(AppPrefKey.allCases.map(\.rawValue)), "AppPrefKey")
    }

    /// Every page is made of sections, and a page that shows a setting has a section for it.
    func testEveryPageHasSections() {
        for tab in SettingsTab.allCases {
            XCTAssertFalse(SettingsSection.sections(on: tab).isEmpty, "\(tab.title) has no sections")
        }
        let sectionTabs = Set(SettingsSection.allCases.map(\.tab))
        for placement in SettingsRegistry.all {
            XCTAssertTrue(sectionTabs.contains(placement.tab), "\(placement.key): \(placement.tab.title) has no sections")
        }
    }

    // MARK: The app's Settings sources

    /// <repo>/mac/Sources/NeedsYou (this file is three directories below the repo root, here
    /// and as its symlink in Sources/NeedsYouSelfTest).
    private var appSources: URL {
        var url = URL(fileURLWithPath: "\(#filePath)")
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("mac/Sources/NeedsYou")
    }

    /// Writes a section may make to a key on another page, on purpose.
    private static let crossPageWrites: Set<String> = [
        "welcome runLocalHub",   // General's first-run "Use the hub built into this app"
    ]

    /// Reads every app source: `// settings-section: <case>` starts a section's code, which
    /// runs to the next marker, `// settings-section-end` or the end of the file. Inside, a
    /// binding (`$settings.ui.x`) or an assignment (`settings.ui.x = `) must be a path
    /// registered to the section's page. Outside, no Settings control may bind a setting.
    func testSectionsWriteOnlyTheirPagesKeys() throws {
        let binding = try NSRegularExpression(pattern: #"\$(settings|phase3|updates)\.([A-Za-z0-9_.]*[A-Za-z0-9_])"#)
        let assignment = try NSRegularExpression(pattern: #"(?<![\w$.])(settings|phase3|updates)\.([A-Za-z0-9_.]*[A-Za-z0-9_])\s*=(?!=)"#)
        let marker = try NSRegularExpression(pattern: #"^\s*// settings-section: (\w+)\s*$"#)

        guard let files = FileManager.default.enumerator(atPath: appSources.path) else {
            return XCTFail("app sources not found at \(appSources.path)")
        }
        var marked = Set<SettingsSection>()
        var checked = 0
        for case let name as String in files where name.hasSuffix(".swift") {
            let text = try String(contentsOf: appSources.appendingPathComponent(name), encoding: .utf8)
            var section: SettingsSection?
            for (n, raw) in text.components(separatedBy: "\n").enumerated() {
                let line = raw as NSString
                let whole = NSRange(location: 0, length: line.length)
                if let m = marker.firstMatch(in: raw, range: whole) {
                    let caseName = line.substring(with: m.range(at: 1))
                    section = SettingsSection(rawValue: caseName)
                    XCTAssertNotNil(section, "\(name):\(n + 1): no SettingsSection.\(caseName)")
                    if let section { marked.insert(section) }
                    continue
                }
                if raw.trimmingCharacters(in: .whitespaces) == "// settings-section-end" { section = nil; continue }
                if raw.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                for (regex, isBinding) in [(binding, true), (assignment, false)] {
                    for m in regex.matches(in: raw, range: whole) {
                        let root = line.substring(with: m.range(at: 1))
                        let rest = line.substring(with: m.range(at: 2))
                        let path = root == "settings" ? rest : "\(root).\(rest)"
                        guard let section else {
                            if isBinding { XCTFail("\(name):\(n + 1): \(path) is bound outside any settings-section") }
                            continue
                        }
                        checked += 1
                        if Self.crossPageWrites.contains("\(section.rawValue) \(path)") { continue }
                        guard let placement = SettingsRegistry.placement(forPath: path) else {
                            XCTFail("\(name):\(n + 1): \(path) isn't registered (SettingsRegistry.all)")
                            continue
                        }
                        XCTAssertEqual(placement.tab, section.tab,
                                       "\(name):\(n + 1): section \(section.rawValue) is on \(section.tab.title), but \(placement.key) is registered to \(placement.tab.title)")
                    }
                }
            }
        }
        XCTAssertEqual(Set(SettingsSection.allCases).subtracting(marked).map(\.rawValue).sorted(), [],
                       "sections with no `// settings-section:` marker in the app")
        XCTAssertTrue(checked >= 60, "only \(checked) setting writes found: the scan is broken")

        // The window builds its pages from Core's section list.
        let window = try String(contentsOf: appSources.appendingPathComponent("SettingsWindow.swift"), encoding: .utf8)
        XCTAssertTrue(window.contains("SettingsSection.sections(on: page)"))
    }

    /// What `save` writes, by key (less what an untouched suite already shows).
    private func savedValues(_ save: (UserDefaults) -> Void) -> [String: NSObject] {
        let empty = Set(TestDefaults.make(emptySuite).dictionaryRepresentation().keys)
        let store = TestDefaults.make(suite)
        save(store)
        return store.dictionaryRepresentation().filter { !empty.contains($0.key) }.compactMapValues { $0 as? NSObject }
    }

    /// Advanced → Reset Appearance: with every value changed, the reset puts back exactly the
    /// keys the registry calls look, and keeps every behaviour key.
    func testAppearanceResetResetsLookOnly() {
        var ui = UIPrefs()
        ui.panelSize = .large; ui.textSize = .large; ui.alertUrgent = .bright; ui.alertOther = .subtle
        ui.panelOpacity = 0.7; ui.panelHoverOpacity = 0.9; ui.pillOpacity = 0.5; ui.pillHoverOpacity = 0.6
        ui.maxVisibleCards = 3; ui.cardBodies = .hidden; ui.compactLinks = true
        ui.pillSize = .large; ui.pillDetail = .dot; ui.pillSplit = .priority; ui.pillShowNew = false
        ui.previewSeconds = 5; ui.collapseOnClickOutside = false; ui.backdrop = 0.6; ui.expandedListHeight = 300
        ui.theme = .ocean; ui.accent = .preset(.blue); ui.background = .solid
        ui.arrivalUrgent = .bounce; ui.arrivalOther = .shake; ui.arrivalRepeats = 3; ui.arrivalSpeed = .fast
        ui.urgentReminderMinutes = 5; ui.panelShape = .capsule; ui.cardDensity = .compact
        var usage = UsagePrefs()
        usage.inPanel = false; usage.onPill = false; usage.pillStyle = .rings; usage.pillArrangement = .row
        usage.pillSize = .small; usage.pillNumbers = true; usage.providers = ["claude"]; usage.windows = .weekly
        usage.hideUnderPct = 50; usage.warnPct = 90

        let checks: [(String, (UserDefaults) -> Void, (UserDefaults) -> Void, (UserDefaults) -> Void)] = [
            ("UIPrefs", { ui.save(to: $0) }, { AppearanceReset.ui(ui).save(to: $0) }, { UIPrefs().save(to: $0) }),
            ("UsagePrefs", { usage.save(to: $0) }, { AppearanceReset.usage(usage).save(to: $0) }, { UsagePrefs().save(to: $0) }),
        ]
        for (owner, changed, reset, standard) in checks {
            let before = savedValues(changed), after = savedValues(reset), defaults = savedValues(standard)
            XCTAssertEqual(Set(before.keys), Set(defaults.keys), owner)
            for key in defaults.keys.sorted() {
                // The fixture changes every value, so a new field can't slip through unchecked.
                XCTAssertNotEqual(before[key], defaults[key], "\(owner).\(key): change it in this test's fixture")
                guard let placement = SettingsRegistry.placement(forKey: key) else {
                    XCTFail("\(owner).\(key) isn't registered"); continue
                }
                switch placement.kind {
                case .look: XCTAssertEqual(after[key], defaults[key], "\(key) is look: Reset Appearance must reset it")
                case .behaviour: XCTAssertEqual(after[key], before[key], "\(key) is behaviour: Reset Appearance must keep it")
                }
            }
        }
        XCTAssertEqual(SettingsRegistry.placement(forKey: EdgeGlowMode.defaultsKey)?.kind, .look)
        XCTAssertEqual(AppearanceReset.edgeGlow, EdgeGlowMode.standard)
        XCTAssertFalse(AppearanceReset.isDefault(ui: ui, usage: UsagePrefs(), edgeGlow: .off))
        XCTAssertFalse(AppearanceReset.isDefault(ui: UIPrefs(), usage: UsagePrefs(), edgeGlow: .urgent))
        XCTAssertTrue(AppearanceReset.isDefault(ui: AppearanceReset.ui(ui), usage: AppearanceReset.usage(usage), edgeGlow: .off))
    }

    /// What this layout moved, and that the old page names still land.
    func testMovedSettingsAndOldNames() {
        XCTAssertEqual(SettingsRegistry.placement(forKey: UIPrefs.Key.expandedListHeight)?.tab, .cards)
        XCTAssertEqual(SettingsRegistry.placement(forKey: EdgeGlowMode.defaultsKey)?.tab, .alertStyle)
        XCTAssertEqual(SettingsRegistry.placement(forKey: UsagePrefs.Key.onPill)?.tab, .panel)
        XCTAssertEqual(SettingsRegistry.placement(forKey: UsagePrefs.Key.pillStyle)?.tab, .usageMeters)
        XCTAssertEqual(SettingsSection.usageSetup.tab, .integrations)
        XCTAssertEqual(SettingsTab(name: "usage"), .usageMeters)
        XCTAssertEqual(SettingsTab(name: "appearance"), .theme)
        for tab in SettingsTab.allCases { XCTAssertEqual(SettingsTab(name: tab.rawValue), tab) }
    }
}
