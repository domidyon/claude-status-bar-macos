import Foundation

public struct CodexUsageWindow: Equatable, Sendable {
    public let usedPercent: Double
    public let duration: TimeInterval
    public let resetsAt: Date?

    public init(usedPercent: Double, duration: TimeInterval, resetsAt: Date?) {
        self.usedPercent = usedPercent
        self.duration = duration
        self.resetsAt = resetsAt
    }
}

public struct CodexUsageSnapshot: Equatable, Sendable {
    public let primary: CodexUsageWindow
    public let secondary: CodexUsageWindow?

    public static func parse(_ data: Data) -> CodexUsageSnapshot? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rateLimit = object["rate_limit"] as? [String: Any],
              let primary = window(from: rateLimit["primary_window"]) else { return nil }
        return CodexUsageSnapshot(primary: primary, secondary: window(from: rateLimit["secondary_window"]))
    }

    private static func window(from value: Any?) -> CodexUsageWindow? {
        guard let object = value as? [String: Any],
              let percent = object["used_percent"] as? NSNumber,
              let duration = object["limit_window_seconds"] as? NSNumber else { return nil }
        let resetsAt = (object["reset_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        return CodexUsageWindow(usedPercent: percent.doubleValue,
                                duration: duration.doubleValue, resetsAt: resetsAt)
    }
}

public enum CodexUsageError: Error, Equatable {
    case unauthorized, rateLimited, http(Int), network, malformed
}

public struct CodexUsageClient: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    /// Uses the existing Codex CLI token only in the request header. It is
    /// never persisted or logged by this client.
    public func fetch(token: String) async throws -> CodexUsageSnapshot {
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("codex-status-bar", forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw CodexUsageError.network }
        guard let http = response as? HTTPURLResponse else { throw CodexUsageError.network }
        switch http.statusCode {
        case 200...299: break
        case 401: throw CodexUsageError.unauthorized
        case 429: throw CodexUsageError.rateLimited
        default: throw CodexUsageError.http(http.statusCode)
        }
        guard let snapshot = CodexUsageSnapshot.parse(data) else { throw CodexUsageError.malformed }
        return snapshot
    }
}

public struct CodexUsageState: Equatable, Sendable {
    public let snapshot: CodexUsageSnapshot?
    public let unavailable: Bool

    public init(snapshot: CodexUsageSnapshot?, unavailable: Bool = false) {
        self.snapshot = snapshot
        self.unavailable = unavailable
    }

    public static func failed(previous: CodexUsageState?) -> CodexUsageState {
        CodexUsageState(snapshot: previous?.snapshot, unavailable: previous?.snapshot == nil)
    }
}
