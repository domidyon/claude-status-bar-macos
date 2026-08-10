import Foundation
import Testing
@testable import StatusBarCore

@Suite("CodexAccountStore")
struct CodexAccountStoreTests {
    @Test("imports current and backup auth files and swaps the CLI auth file")
    func importsAndSwitches() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try auth(email: "one@example.com").write(to: root.appendingPathComponent("auth.json"))
        try auth(email: "two@example.com").write(to: root.appendingPathComponent("auth.json.bak"))
        let store = CodexAccountStore(codexRoot: root)
        let accounts = await store.accounts()
        #expect(accounts.map(\.email) == ["one@example.com", "two@example.com"])
        #expect(accounts[0].isActive)
        #expect(await store.switchTo(id: accounts[1].id))
        let switched = await store.accounts()
        #expect(switched.map(\.isActive) == [false, true])
        #expect(CodexAccountStore.email(from: try Data(contentsOf: root.appendingPathComponent("auth.json"))) == "two@example.com")
    }

    @Test("returns no accounts without a Codex auth file")
    func noAuthFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(await CodexAccountStore(codexRoot: root).accounts().isEmpty)
    }

    @Test("retains prior accounts when Codex replaces auth.json externally")
    func reconcilesExternalLogin() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try auth(email: "one@example.com", accountID: "one").write(to: root.appendingPathComponent("auth.json"))
        let store = CodexAccountStore(codexRoot: root)
        #expect(await store.accounts().map(\.email) == ["one@example.com"])

        try auth(email: "two@example.com", accountID: "two").write(to: root.appendingPathComponent("auth.json"))
        let accounts = await store.accounts()
        #expect(accounts.map(\.email) == ["one@example.com", "two@example.com"])
        #expect(accounts.map(\.isActive) == [false, true])
        #expect(CodexAccountStore.email(from: try Data(contentsOf: accounts[0].authURL)) == "one@example.com")
    }

    @Test("refreshes the active vault copy after Codex rotates its token")
    func reconcilesTokenRefresh() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try auth(email: "one@example.com", accountID: "one", marker: "old")
            .write(to: root.appendingPathComponent("auth.json"))
        let store = CodexAccountStore(codexRoot: root)
        let account = try #require(await store.accounts().first)
        try auth(email: "one@example.com", accountID: "one", marker: "new")
            .write(to: root.appendingPathComponent("auth.json"))

        _ = await store.accounts()
        #expect(try Data(contentsOf: account.authURL) == auth(email: "one@example.com", accountID: "one", marker: "new"))
    }

    private func auth(email: String, accountID: String? = nil, marker: String? = nil) -> Data {
        let payload = Data("{\"https://api.openai.com/profile\":{\"email\":\"\(email)\"}}".utf8)
            .base64EncodedString().replacingOccurrences(of: "=", with: "")
        let account = accountID.map { ",\"account_id\":\"\($0)\"" } ?? ""
        let extra = marker.map { ",\"marker\":\"\($0)\"" } ?? ""
        return Data("{\"tokens\":{\"access_token\":\"x.\(payload).y\"\(account)\(extra)}}".utf8)
    }
}

@Suite("CodexUsage")
struct CodexUsageTests {
    @Test("parses primary and secondary quota windows")
    func parsesWindows() {
        let data = Data(#"{"rate_limit":{"primary_window":{"used_percent":42,"limit_window_seconds":604800,"reset_at":1784503677},"secondary_window":{"used_percent":8,"limit_window_seconds":18000,"reset_at":1784100000}}}"#.utf8)
        let snapshot = CodexUsageSnapshot.parse(data)
        #expect(snapshot?.primary.usedPercent == 42)
        #expect(snapshot?.primary.duration == 604800)
        #expect(snapshot?.secondary?.usedPercent == 8)
    }

    @Test("rejects a response without a primary quota window")
    func rejectsInvalidResponse() {
        #expect(CodexUsageSnapshot.parse(Data(#"{"rate_limit":{}}"#.utf8)) == nil)
    }

    @Test("keeps the last good snapshot after a refresh failure")
    func failedRefreshKeepsSnapshot() throws {
        let snapshot = try #require(CodexUsageSnapshot.parse(Data(#"{"rate_limit":{"primary_window":{"used_percent":42,"limit_window_seconds":18000}}}"#.utf8)))
        let state = CodexUsageState.failed(previous: CodexUsageState(snapshot: snapshot))
        #expect(state.snapshot == snapshot)
        #expect(!state.unavailable)
        #expect(CodexUsageState.failed(previous: nil).unavailable)
    }
}
