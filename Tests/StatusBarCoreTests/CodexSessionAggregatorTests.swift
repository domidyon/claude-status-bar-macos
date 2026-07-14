import Foundation
import Testing
@testable import StatusBarCore

@Suite("CodexSessionAggregator")
struct CodexSessionAggregatorTests {
    @Test("shows an active tool call from an unfinished Codex task")
    func activeToolCall() throws {
        let root = try fixture("""
        {"timestamp":"2026-07-14T20:00:00Z","type":"turn_context","payload":{"cwd":"/tmp/project"}}
        {"timestamp":"2026-07-14T20:00:01Z","type":"event_msg","payload":{"type":"task_started"}}
        {"timestamp":"2026-07-14T20:00:03Z","type":"response_item","payload":{"type":"custom_tool_call","name":"functions.exec"}}
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = CodexSessionAggregator.loadSessions(from: root,
                                                           now: ISO8601.parse("2026-07-14T20:00:04Z")!)
        #expect(sessions.count == 1)
        #expect(sessions[0].state == .tool)
        #expect(sessions[0].label == "Running")
        #expect(sessions[0].cwd == "/tmp/project")
    }

    @Test("hides a completed task")
    func completedTask() throws {
        let root = try fixture("""
        {"timestamp":"2026-07-14T20:00:01Z","type":"event_msg","payload":{"type":"task_started"}}
        {"timestamp":"2026-07-14T20:00:03Z","type":"event_msg","payload":{"type":"task_complete"}}
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(CodexSessionAggregator.loadSessions(from: root,
                                                     now: ISO8601.parse("2026-07-14T20:00:04Z")!).isEmpty)
    }

    private func fixture(_ content: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(content.utf8).write(to: root.appendingPathComponent("rollout.jsonl"))
        return root
    }
}
