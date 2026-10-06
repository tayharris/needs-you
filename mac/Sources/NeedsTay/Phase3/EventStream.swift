import Foundation
import NeedsTayCore

/// Optional `GET /v1/stream` (server-sent events). PLAN.md doesn't define the event
/// payload, so any event is treated as a nudge to poll now; polling stays the source of
/// truth. A 404 means the hub has no stream, and it stops trying until restarted.
final class EventStream: @unchecked Sendable {
    private var task: Task<Void, Never>?

    func start(config: HubConfig, onEvent: @escaping @MainActor () -> Void) {
        stop()
        task = Task.detached(priority: .utility) {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 600     // idle gap between events
            cfg.timeoutIntervalForResource = 24 * 3600
            let session = URLSession(configuration: cfg)
            defer { session.invalidateAndCancel() }

            var backoff: Double = 2
            while !Task.isCancelled {
                var request = HubClient.makeRequest(
                    url: config.baseURL.appendingPathComponent("v1/stream"), method: "GET", token: config.token)
                request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if status == 404 || status == 405 || status == 501 { return }  // no stream on this hub
                    if status == 401 || status == 403 { return }                   // polling reports auth errors
                    guard (200..<300).contains(status) else { throw HubError.http(status: status) }
                    backoff = 2
                    await onEvent() // catch up on anything missed while disconnected
                    var lastPoke = Date.distantPast
                    for try await line in bytes.lines {
                        if Task.isCancelled { return }
                        guard line.hasPrefix("data:") || line.hasPrefix("event:") else { continue }
                        // Coalesce bursts; AppModel also ignores overlapping polls.
                        if Date().timeIntervalSince(lastPoke) > 0.5 {
                            lastPoke = Date()
                            await onEvent()
                        }
                    }
                } catch {
                    if Task.isCancelled { return }
                }
                try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                backoff = min(backoff * 2, 300)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    deinit { task?.cancel() }
}
