import Foundation
import NeedsYouCore
import os

/// Reads the rows for the panel's Orca section: `orca worktree ps --json` on this Mac, then
/// through each paired environment from `orca environment list` (at most 8, as the Terminal
/// button), each from the fixed CLI path with no shell and a 10 s limit. Read-only.
enum OrcaStripRunner {
    private static let log = Logger(subsystem: AppIdentity.logSubsystem, category: "orca-strip")
    private static let queue = DispatchQueue(label: "orca-strip", qos: .utility)

    /// Calls `done` on the main actor with the rows, or nil when there's no `orca` CLI or
    /// nothing answered.
    static func fetch(_ done: @escaping @MainActor ([OrcaWorktreeRow]?) -> Void) {
        queue.async {
            let rows = read()
            DispatchQueue.main.async { MainActor.assumeIsolated { done(rows) } }
        }
    }

    private static func read() -> [OrcaWorktreeRow]? {
        guard let cli = OrcaJumpRunner.cliPath else { return nil }
        var rows: [OrcaWorktreeRow] = []
        var answered = false
        if let out = OrcaJumpRunner.runOrca(cli, OrcaWorktrees.psArguments(environment: nil), timeout: 10),
           let local = OrcaWorktrees.parse(out, environment: nil) {
            rows += local
            answered = true
        }
        if let list = OrcaJumpRunner.runOrca(cli, OrcaJump.environmentListArguments, timeout: 10) {
            for name in OrcaJump.environmentNames(list) {
                guard let out = OrcaJumpRunner.runOrca(cli, OrcaWorktrees.psArguments(environment: name), timeout: 10),
                      let env = OrcaWorktrees.parse(out, environment: name) else {
                    log.info("orca worktree ps via \(name, privacy: .public) gave no rows")
                    continue
                }
                rows += env
                answered = true
            }
        }
        return answered ? rows : nil
    }
}
