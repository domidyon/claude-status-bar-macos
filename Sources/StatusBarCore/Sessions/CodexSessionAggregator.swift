import Foundation

/// Derives live Codex CLI activity from its local rollout JSONL files. A turn
/// starts with `task_started` and ends with `task_complete`; intervening
/// reasoning and tool records determine the animated status-bar state.
public enum CodexSessionAggregator {
    public static let staleAfter: TimeInterval = 900
    private static let tailBytes: UInt64 = 256 * 1024

    public static func loadSessions(from root: URL, now: Date) -> [SessionRecord] {
        let fm = FileManager.default
        let calendar = Calendar.current
        let files = [0, -1].flatMap { offset -> [URL] in
            guard let date = calendar.date(byAdding: .day, value: offset, to: now) else { return [] }
            let components = calendar.dateComponents([.year, .month, .day], from: date)
            guard let year = components.year, let month = components.month, let day = components.day else { return [] }
            let directory = root.appendingPathComponent(String(year), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", month), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", day), isDirectory: true)
            return (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        }.filter { $0.pathExtension == "jsonl" }
        // The direct-file fallback keeps the parser easy to test and supports
        // Codex layouts from before the date-partitioned sessions directory.
        let candidates = files.isEmpty
            ? ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "jsonl" }
            : files
        return candidates.compactMap { session(from: $0, now: now) }
            .sorted { $0.updatedAt < $1.updatedAt }
    }

    private static func session(from file: URL, now: Date) -> SessionRecord? {
        guard let data = tail(of: file), let text = String(data: data, encoding: .utf8) else { return nil }
        var cwd = ""
        var start: Date?
        var state: SessionState = .idle
        var label: String?
        var updatedAt: Date?

        for line in text.split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let timestamp = (object["timestamp"] as? String).flatMap(ISO8601.parse),
                  let type = object["type"] as? String else { continue }
            let payload = object["payload"] as? [String: Any] ?? [:]
            if type == "turn_context", let value = payload["cwd"] as? String { cwd = value }
            let event = payload["type"] as? String
            switch (type, event) {
            case ("event_msg", "task_started"):
                start = timestamp
                state = .thinking
                label = nil
                updatedAt = timestamp
            case ("event_msg", "task_complete"):
                start = nil
                state = .idle
                label = nil
                updatedAt = timestamp
            case ("response_item", "reasoning") where start != nil:
                state = .thinking
                label = nil
                updatedAt = timestamp
            case ("response_item", "custom_tool_call"), ("response_item", "function_call"):
                guard start != nil else { continue }
                state = .tool
                label = toolLabel(payload["name"] as? String)
                updatedAt = timestamp
            case ("response_item", "custom_tool_call_output"), ("response_item", "function_call_output"):
                guard start != nil else { continue }
                state = .thinking
                label = nil
                updatedAt = timestamp
            default:
                continue
            }
        }

        guard let startedAt = start, let last = updatedAt,
              now.timeIntervalSince(last) <= staleAfter else { return nil }
        return SessionRecord(sessionId: "codex-\(file.deletingPathExtension().lastPathComponent)",
                             state: state, label: label, cwd: cwd, startedAt: startedAt,
                             busySince: startedAt, updatedAt: last)
    }

    private static func tail(of url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let offset = size > tailBytes ? size - tailBytes : 0
        try? handle.seek(toOffset: offset)
        return try? handle.readToEnd()
    }

    private static func toolLabel(_ name: String?) -> String {
        switch name {
        case "functions.exec", "exec", "shell": return "Running"
        case "functions.apply_patch", "apply_patch": return "Editing"
        case "web.run", "web_search": return "Browsing"
        default: return "Working"
        }
    }
}
