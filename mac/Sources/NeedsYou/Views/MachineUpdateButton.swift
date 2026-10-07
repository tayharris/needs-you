import NeedsYouCore
import SwiftUI

/// The trailing control on a machine's row (Settings → Access / Machines): **Request update**
/// while its CLI is older than this app's version or hasn't reported one, "Update requested
/// 5m ago" with **Cancel** while a request stands, "Up to date" once it's current.
///
/// "Current" is judged against this app's own version: its hub serves that CLI on /dl, so it
/// is the newest a machine's `needs-you update` can install from it (docs/guides/updates.md).
struct MachineUpdateButton: View {
    let token: TokenSummary
    @ObservedObject var connect: ConnectController

    private static let target: SemVer? =
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).flatMap { SemVer($0) }

    private var busy: Bool {
        if case .working = connect.accessStatus { return true }
        return false
    }

    var body: some View {
        switch MachineUpdateState(token: token, target: Self.target) {
        case .notApplicable:
            EmptyView()
        case .current:
            Text("Up to date").font(.caption).foregroundStyle(.secondary)
        case .outdated:
            Button("Request update") { connect.requestUpdate(token) }
                .disabled(busy)
                .help("Asks this machine to run needs-you update from your hub. With auto-update on it updates itself; otherwise it reminds whoever uses it, once a day.")
        case .requested(let at):
            HStack(spacing: 6) {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(MachineUpdateState.requestedLabel(at, now: context.date))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Cancel") { connect.clearUpdateRequest(token) }
                    .buttonStyle(.borderless).font(.caption)
                    .disabled(busy)
            }
        }
    }
}
