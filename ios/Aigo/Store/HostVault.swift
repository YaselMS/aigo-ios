import Foundation
import Security

/// Minimal generic-password Keychain wrapper.
enum Keychain {
    static let service = "dev.aigo.app"

    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    @discardableResult
    static func save(_ data: Data, account: String) -> Bool {
        let query = baseQuery(account)
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func load(account: String) -> Data? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess else { return nil }
        return out as? Data
    }

    static func delete(account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }
}

/// Persists the list of paired hosts as one JSON blob in the Keychain.
/// Some sideloading setups strip Keychain entitlements; in that case the
/// blob falls back to a file in Application Support with complete file
/// protection (encrypted while the phone is locked).
enum HostVault {
    private static let account = "hosts.v1"

    private static var fallbackURL: URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("hosts.v1.json")
    }

    static func load() -> [HostCredentials] {
        if let data = Keychain.load(account: account),
           let hosts = try? JSONDecoder().decode([HostCredentials].self, from: data) {
            return hosts
        }
        if let url = fallbackURL, let data = try? Data(contentsOf: url),
           let hosts = try? JSONDecoder().decode([HostCredentials].self, from: data) {
            return hosts
        }
        return []
    }

    static func save(_ hosts: [HostCredentials]) {
        guard let data = try? JSONEncoder().encode(hosts) else { return }
        if Keychain.save(data, account: account) {
            if let url = fallbackURL {
                try? FileManager.default.removeItem(at: url)
            }
            return
        }
        if let url = fallbackURL {
            try? data.write(to: url, options: [.atomic, .completeFileProtection])
        }
    }
}
