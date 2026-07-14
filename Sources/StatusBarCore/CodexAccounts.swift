import Foundation

public struct CodexAccount: Equatable, Sendable, Identifiable {
    public let id: String
    public let email: String?
    public let isActive: Bool
    public let authURL: URL

    public init(id: String, email: String?, isActive: Bool, authURL: URL) {
        self.id = id
        self.email = email
        self.isActive = isActive
        self.authURL = authURL
    }

    public var label: String { email ?? id }
}

/// Maintains named, private copies of Codex CLI auth files and swaps the active
/// one into `~/.codex/auth.json`. Codex reads that file on startup, so every new
/// CLI session uses the account chosen in the menu bar.
public actor CodexAccountStore {
    private struct Index: Codable {
        struct Entry: Codable {
            let id: String
            let email: String?
            let accountID: String?
            let file: String
        }

        var activeID: String
        var accounts: [Entry]
    }

    private let codexRoot: URL
    private let vaultRoot: URL
    private let authFile: URL
    private let backupFile: URL
    public init(codexRoot: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex", isDirectory: true)) {
        self.codexRoot = codexRoot
        self.vaultRoot = codexRoot.appendingPathComponent("accounts", isDirectory: true)
        self.authFile = codexRoot.appendingPathComponent("auth.json")
        self.backupFile = codexRoot.appendingPathComponent("auth.json.bak")
    }

    public func accounts() -> [CodexAccount] {
        guard let index = loadOrBootstrap() else { return [] }
        return index.accounts.map { entry in
            CodexAccount(id: entry.id, email: entry.email, isActive: entry.id == index.activeID,
                         authURL: vaultRoot.appendingPathComponent(entry.file))
        }
    }

    /// Saves the current CLI credentials into their active vault entry before
    /// atomically making the selected entry active. That preserves refreshes
    /// performed by Codex between switches.
    @discardableResult
    public func switchTo(id: String) -> Bool {
        guard var index = loadOrBootstrap(),
              index.activeID != id,
              let current = index.accounts.first(where: { $0.id == index.activeID }),
              let target = index.accounts.first(where: { $0.id == id }) else { return false }
        do {
            try copy(authFile, to: vaultRoot.appendingPathComponent(current.file))
            try copy(vaultRoot.appendingPathComponent(target.file), to: authFile)
            index.activeID = id
            try writeIndex(index)
            return true
        } catch {
            return false
        }
    }

    private func loadOrBootstrap() -> Index? {
        if let index = loadIndex() { return reconcile(index) }
        return bootstrap()
    }

    /// Codex can replace `auth.json` itself after `codex login`. Fold that
    /// account into the vault instead of leaving the index pointed at stale
    /// credentials or forgetting an account that was added outside this app.
    private func reconcile(_ storedIndex: Index) -> Index {
        guard let data = try? Data(contentsOf: authFile) else { return storedIndex }
        let email = Self.email(from: data)
        let accountID = Self.accountID(from: data)
        guard email != nil || accountID != nil else { return storedIndex }

        var index = storedIndex
        if let position = index.accounts.firstIndex(where: {
            (accountID != nil && $0.accountID == accountID) ||
            (email != nil && $0.email?.caseInsensitiveCompare(email!) == .orderedSame)
        }) {
            let entry = index.accounts[position]
            try? copyIfChanged(data, to: vaultRoot.appendingPathComponent(entry.file))
            if index.activeID != entry.id {
                index.activeID = entry.id
                try? writeIndex(index)
            }
            return index
        }

        let id = Self.uniqueIdentifier(email: email, existing: Set(index.accounts.map(\.id)))
        let entry = Index.Entry(id: id, email: email, accountID: accountID, file: "\(id).json")
        do {
            try copyIfChanged(data, to: vaultRoot.appendingPathComponent(entry.file))
            index.accounts.append(entry)
            index.activeID = id
            try writeIndex(index)
            return index
        } catch {
            return storedIndex
        }
    }

    private func loadIndex() -> Index? {
        let url = vaultRoot.appendingPathComponent("index.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Index.self, from: data)
    }

    /// The current and prior local auth files are the two existing accounts.
    /// Import is one-time only; after that the vault is the source of truth.
    private func bootstrap() -> Index? {
        guard FileManager.default.fileExists(atPath: authFile.path) else { return nil }
        do {
            try FileManager.default.createDirectory(at: vaultRoot, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let sources = [authFile, backupFile].filter { FileManager.default.fileExists(atPath: $0.path) }
            var entries: [Index.Entry] = []
            for source in sources {
                let data = try Data(contentsOf: source)
                let email = Self.email(from: data)
                let accountID = Self.accountID(from: data)
                guard !entries.contains(where: {
                    (accountID != nil && $0.accountID == accountID) ||
                    (email != nil && $0.email?.caseInsensitiveCompare(email!) == .orderedSame)
                }) else { continue }
                let id = Self.uniqueIdentifier(email: email, existing: Set(entries.map(\.id)))
                let file = "\(id).json"
                try copy(source, to: vaultRoot.appendingPathComponent(file))
                entries.append(Index.Entry(id: id, email: email, accountID: accountID, file: file))
            }
            guard let active = entries.first else { return nil }
            let index = Index(activeID: active.id, accounts: entries)
            try writeIndex(index)
            return index
        } catch {
            return nil
        }
    }

    private func writeIndex(_ index: Index) throws {
        let data = try JSONEncoder().encode(index)
        try AtomicFile.write(data, to: vaultRoot.appendingPathComponent("index.json"))
        try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                              ofItemAtPath: vaultRoot.appendingPathComponent("index.json").path)
    }

    private func copy(_ source: URL, to destination: URL) throws {
        let data = try Data(contentsOf: source)
        try AtomicFile.write(data, to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    private func copyIfChanged(_ data: Data, to destination: URL) throws {
        if (try? Data(contentsOf: destination)) == data { return }
        try AtomicFile.write(data, to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    private static func uniqueIdentifier(email: String?, existing: Set<String>) -> String {
        let base = email.map {
            $0.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-",
                                                 options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        }.flatMap { $0.isEmpty ? nil : $0 } ?? "account"
        if !existing.contains(base) { return base }
        var suffix = 2
        while existing.contains("\(base)-\(suffix)") { suffix += 1 }
        return "\(base)-\(suffix)"
    }

    /// Reads only the unverified JWT payload's profile email for display. The
    /// token itself is never retained, logged, or sent anywhere by this class.
    static func email(from authData: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: authData) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count > 1 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = object["https://api.openai.com/profile"] as? [String: Any] else { return nil }
        return profile["email"] as? String
    }

    static func accountID(from authData: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: authData) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any] else { return nil }
        return tokens["account_id"] as? String
    }
}
