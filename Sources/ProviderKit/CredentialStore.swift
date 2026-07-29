import Foundation
import Security

/// Where API keys live. Behind a protocol so the provider layer can be
/// exercised without touching the user's real Keychain (and so a future
/// migration — e.g. the data-protection keychain once the app ships signed —
/// doesn't reach into call sites).
public protocol CredentialStore: Sendable {
    func key(for profileID: String) throws -> String?
    func store(_ key: String, for profileID: String) throws
    func delete(for profileID: String) throws
}

/// Keychain Services, generic-password items keyed by profile id under one
/// service (SPEC §8: keys live *only* here — never in the DB, settings rows, or
/// logs).
///
/// Uses the **file-based** keychain deliberately: the data-protection keychain
/// (`kSecUseDataProtectionKeychain`) rejects an unsigned or unentitled binary
/// with `errSecMissingEntitlement (-34018)`, which would make these credentials
/// untestable and would break `swift test` on any machine — proven by probe
/// before this was written (slice-02 doc Notes). Revisit at M5, when signing +
/// a keychain-access-group entitlement land.
public struct KeychainCredentialStore: CredentialStore {
    /// Production service name. Tests pass their own so a run can never touch
    /// the author's real credentials.
    public static let productionService = "io.macapy.app"

    let service: String

    public init(service: String = KeychainCredentialStore.productionService) {
        self.service = service
    }

    public func key(for profileID: String) throws -> String? {
        var query = baseQuery(profileID: profileID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                throw KeychainError.unexpectedItemFormat
            }
            return String(decoding: data, as: UTF8.self)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.status(status)
        }
    }

    /// Adds or replaces. `SecItemAdd` returns `errSecDuplicateItem` for an
    /// existing account, so a second store for the same profile updates in
    /// place — re-entering a rotated key must not fail.
    public func store(_ key: String, for profileID: String) throws {
        let data = Data(key.utf8)
        var attributes = baseQuery(profileID: profileID)
        attributes[kSecValueData as String] = data

        let status = SecItemAdd(attributes as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let update = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(baseQuery(profileID: profileID) as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else { throw KeychainError.status(updateStatus) }
        default:
            throw KeychainError.status(status)
        }
    }

    public func delete(for profileID: String) throws {
        let status = SecItemDelete(baseQuery(profileID: profileID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.status(status)
        }
    }

    /// Removes every key under this service. Exists for the tests' cleanup and
    /// for the app's "delete everything" path (FR-013).
    ///
    /// Loops on purpose: the file-based keychain's `SecItemDelete` removes a
    /// *single* matching item per call, so one call silently left the other
    /// profiles' keys on the machine while returning success. The bound is
    /// there so a keychain that kept returning `errSecSuccess` without deleting
    /// couldn't spin forever.
    public func deleteAll() throws {
        for _ in 0..<1_000 {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
            ]
            let status = SecItemDelete(query as CFDictionary)
            switch status {
            case errSecSuccess: continue
            case errSecItemNotFound: return
            default: throw KeychainError.status(status)
            }
        }
        throw KeychainError.status(errSecInternalError)
    }

    private func baseQuery(profileID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID,
        ]
    }
}

public enum KeychainError: Error, Equatable {
    case status(OSStatus)
    case unexpectedItemFormat
}

/// An in-memory `CredentialStore` for tests and previews. Lives in the shipping
/// module (not a test target) because the settings previews need it too; it is
/// never wired into the app's composition root.
public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: String]

    public init(keys: [String: String] = [:]) {
        self.keys = keys
    }

    public func key(for profileID: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return keys[profileID]
    }

    public func store(_ key: String, for profileID: String) throws {
        lock.lock()
        defer { lock.unlock() }
        keys[profileID] = key
    }

    public func delete(for profileID: String) throws {
        lock.lock()
        defer { lock.unlock() }
        keys[profileID] = nil
    }
}
