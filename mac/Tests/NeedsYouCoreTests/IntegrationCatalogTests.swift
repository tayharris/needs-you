#if NEEDSYOU_SELFTEST
import MiniXCTest
#else
import XCTest
#endif
import Foundation
import NeedsYouCore

/// Settings → Integrations: every name, command and prompt in IntegrationCatalog is held to
/// the scripts and guides it comes from, and no prompt carries a token.
final class IntegrationCatalogTests: XCTestCase {
    static var allTests = [
        ("testCatalogIsShortAndUnique", testCatalogIsShortAndUnique),
        ("testSummariesArePlainAndShort", testSummariesArePlainAndShort),
        ("testEveryEnvVarIsReadByItsScript", testEveryEnvVarIsReadByItsScript),
        ("testEveryCommandIsInItsGuide", testEveryCommandIsInItsGuide),
        ("testGuidesCarryTheSamePrompt", testGuidesCarryTheSamePrompt),
        ("testPromptsHoldNothingTokenShaped", testPromptsHoldNothingTokenShaped),
        ("testPromptsSayWhereTheTokenGoes", testPromptsSayWhereTheTokenGoes),
        ("testPromptsMirrorTheInvitePrompt", testPromptsMirrorTheInvitePrompt),
        ("testSecretFilesMatchTheScripts", testSecretFilesMatchTheScripts),
        ("testScriptsAndLaunchAgentsExist", testScriptsAndLaunchAgentsExist),
        ("testGuideLinksAreAllowed", testGuideLinksAreAllowed),
    ]

    /// The repo root: this file sits three directories below it, both in
    /// Tests/NeedsYouCoreTests and as its symlink in Sources/NeedsYouSelfTest.
    private func repo(_ path: String) -> URL {
        var url = URL(fileURLWithPath: "\(#filePath)")
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return url.appendingPathComponent(path)
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOf: repo(path), encoding: .utf8)
    }

    private func script(_ i: Integration) throws -> String { try read("integrations/" + i.script) }

    private func guide(_ i: Integration) throws -> String {
        try read("docs/guides/" + String(i.guide.split(separator: "#")[0]))
    }

    /// Every NEEDS_YOU_* name in a text.
    private func envNames(_ text: String) -> Set<String> {
        let regex = try! NSRegularExpression(pattern: "NEEDS_YOU_[A-Z0-9_]*[A-Z0-9]")
        let range = NSRange(text.startIndex..., in: text)
        return Set(regex.matches(in: text, range: range).compactMap { Range($0.range, in: text).map { String(text[$0]) } })
    }

    private func everything(_ i: Integration) -> String {
        ([i.summary, i.needs, i.agentPrompt] + i.settings.flatMap { [$0.name, $0.detail, $0.example ?? ""] }
            + i.commands.map(\.command)).joined(separator: "\n")
    }

    func testCatalogIsShortAndUnique() {
        let all = IntegrationCatalog.all
        XCTAssertEqual(all.map(\.id), ["linear", "jira", "github-projects", "dependabot", "expiry"])
        XCTAssertEqual(Set(all.map(\.id)).count, all.count)
        XCTAssertEqual(Set(all.map(\.name)).count, all.count)
        for i in all {
            XCTAssertNotNil(IntegrationCatalog.integration(id: i.id))
            XCTAssertFalse(i.settings.isEmpty, i.id)
            XCTAssertTrue(i.commands.count <= 4, "\(i.id): keep it to a few commands")
        }
    }

    func testSummariesArePlainAndShort() {
        for i in IntegrationCatalog.all {
            let sentences = i.summary.components(separatedBy: ". ").count
            XCTAssertTrue(sentences <= 2, "\(i.id) summary is \(sentences) sentences")
            XCTAssertTrue(i.summary.count <= 240, "\(i.id) summary is long: \(i.summary.count)")
            XCTAssertFalse(i.summary.contains("NEEDS_YOU_"), i.id)
        }
    }

    func testEveryEnvVarIsReadByItsScript() throws {
        for i in IntegrationCatalog.all {
            let source = try script(i)
            let names = envNames(everything(i))
            XCTAssertFalse(names.isEmpty, i.id)
            for name in names {
                // The script reads it: get("NAME") or os.environ.get("NAME").
                XCTAssertTrue(source.contains("\"\(name)\""), "\(i.id): \(name) isn't read by \(i.script)")
            }
            for setting in i.settings {
                if let example = setting.example {
                    XCTAssertTrue(example.hasPrefix(setting.name + "="), "\(i.id): \(example)")
                }
            }
        }
    }

    /// Nothing invented: each command is the guide's, byte for byte.
    func testEveryCommandIsInItsGuide() throws {
        for i in IntegrationCatalog.all {
            let text = try guide(i)
            for command in i.commands {
                XCTAssertTrue(text.contains(command.command), "\(i.id): `\(command.command)` isn't in \(i.guide)")
            }
        }
    }

    func testGuidesCarryTheSamePrompt() throws {
        for i in IntegrationCatalog.all {
            XCTAssertTrue(try guide(i).contains(i.agentPrompt), "\(i.guide) doesn't carry \(i.id)'s agent prompt")
        }
    }

    func testPromptsHoldNothingTokenShaped() {
        // Token prefixes for the hub and the tools these pollers talk to, and long random runs.
        let patterns = [
            "\\bny[pi]?_[A-Za-z0-9]", "lin_(api|oauth)_", "\\bgh[pousr]_[A-Za-z0-9]", "github_pat_",
            "ATATT", "\\bxox[a-z]-", "[A-Za-z0-9]{32,}", "Bearer ", "Authorization",
        ]
        for i in IntegrationCatalog.all {
            let text = everything(i)
            XCTAssertEqual(CardCopy.redactSecrets(text), text, i.id)
            for pattern in patterns {
                XCTAssertNil(text.range(of: pattern, options: .regularExpression), "\(i.id) matches \(pattern)")
            }
        }
    }

    func testPromptsSayWhereTheTokenGoes() {
        for i in IntegrationCatalog.all {
            let prompt = i.agentPrompt
            switch i.secret {
            case .file(let path, let noun, let store, _):
                XCTAssertTrue(prompt.contains(path), i.id)
                XCTAssertTrue(prompt.contains("mode 600"), i.id)
                XCTAssertTrue(prompt.contains("paste the \(noun) there myself ("), i.id)
                XCTAssertTrue(prompt.contains("Never ask me for the \(noun)"), i.id)
                XCTAssertTrue(prompt.contains("never read the file"), i.id)
                // The command reads the secret from the keyboard into that file, with no
                // group or other access, and never takes it as an argument.
                XCTAssertTrue(store.contains("umask 077"), i.id)
                XCTAssertTrue(store.contains(path), i.id)
                XCTAssertFalse(prompt.contains("cat \(path)"), i.id)
                XCTAssertTrue(i.needs.contains(path) && i.needs.contains("600"), i.id)
            case .ghScope(let scope):
                XCTAssertTrue(prompt.contains("`gh auth refresh -s \(scope)` in my own terminal"), i.id)
                XCTAssertTrue(prompt.contains("Never ask me for a GitHub token"), i.id)
                XCTAssertTrue(i.needs.contains(scope), i.id)
                XCTAssertTrue(i.commands.contains { $0.command == "gh auth refresh -s \(scope)" }, i.id)
            case .none:
                XCTAssertFalse(prompt.contains("token from"), i.id)
            }
            // The env file holds the machine's needs-you token: append only.
            XCTAssertTrue(prompt.contains("only append lines"), i.id)
            XCTAssertFalse(prompt.contains("cat ~/.config/needs-you/env"), i.id)
        }
    }

    /// Like the invite's agent prompt: says what to set up, needs a working sender first,
    /// and ends with what to do when something fails.
    func testPromptsMirrorTheInvitePrompt() {
        for i in IntegrationCatalog.all {
            let prompt = i.agentPrompt
            XCTAssertTrue(prompt.hasPrefix("Set up needs-you cards for \(i.subject) on this machine."), i.id)
            XCTAssertTrue(prompt.contains(i.guideURL), i.id)
            XCTAssertTrue(prompt.contains("~/.local/bin/needs-you doctor"), i.id)
            XCTAssertTrue(prompt.contains("ask me for an invite link"), i.id)
            XCTAssertTrue(prompt.contains(i.launchAgent), i.id)
            for command in i.commands where command.title != "Store the token" && !command.command.hasPrefix("gh auth") {
                XCTAssertTrue(prompt.contains(command.command), "\(i.id): prompt lacks `\(command.command)`")
            }
            XCTAssertTrue(prompt.hasSuffix("If a run prints an error, fix what it names, or tell me if it needs me."), i.id)
        }
    }

    /// The token file the prompt names is the script's default.
    func testSecretFilesMatchTheScripts() throws {
        for i in IntegrationCatalog.all {
            guard let path = i.secret.path else { continue }
            let file = (path as NSString).lastPathComponent
            XCTAssertTrue(try script(i).contains("\"\(file)\""), "\(i.script) doesn't default to \(file)")
        }
    }

    func testScriptsAndLaunchAgentsExist() {
        for i in IntegrationCatalog.all {
            XCTAssertTrue(FileManager.default.fileExists(atPath: repo("integrations/" + i.script).path), i.script)
            XCTAssertTrue(FileManager.default.fileExists(atPath: repo(i.launchAgent).path), i.launchAgent)
        }
    }

    func testGuideLinksAreAllowed() {
        for i in IntegrationCatalog.all {
            XCTAssertTrue(i.guideURL.hasPrefix("https://github.com/"), i.guideURL)
            XCTAssertTrue(LinkPolicy.isAllowed(i.guideURL), i.guideURL)
        }
    }
}
