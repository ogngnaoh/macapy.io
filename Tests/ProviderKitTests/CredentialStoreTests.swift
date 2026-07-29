import Foundation
import Testing

@testable import ProviderKit

/// Acceptance check 5 (first half): keys round-trip through the real Keychain
/// and can be removed. The "and nowhere else" half is `KeyLeakTests`.
///
/// Every test uses its own random service name rather than the production
/// `io.macapy.app`, so a test run can never touch (or leave junk in) the
/// author's real credentials — the M1 test-pollution lesson applied to the
/// Keychain instead of the DB.
struct CredentialStoreTests {

    private func withStore(_ body: (KeychainCredentialStore) throws -> Void) rethrows {
        let store = KeychainCredentialStore(service: "io.macapy.tests.\(UUID().uuidString)")
        defer { try? store.deleteAll() }
        try body(store)
    }

    @Test func storedKeyRoundTrips() throws {
        try withStore { store in
            try store.store("sk-round-trip", for: "deepseek")
            let stored = try store.key(for: "deepseek")
            #expect(stored == "sk-round-trip")
        }
    }

    @Test func storingTwiceReplacesTheKeyInsteadOfFailing() throws {
        try withStore { store in
            try store.store("sk-old", for: "deepseek")
            try store.store("sk-new", for: "deepseek")
            let stored = try store.key(for: "deepseek")
            #expect(stored == "sk-new")
        }
    }

    @Test func keysAreScopedPerProfile() throws {
        try withStore { store in
            try store.store("sk-deepseek", for: "deepseek")
            try store.store("sk-openai", for: "openai")
            let deepseek = try store.key(for: "deepseek")
            let openai = try store.key(for: "openai")
            #expect(deepseek == "sk-deepseek")
            #expect(openai == "sk-openai")
        }
    }

    @Test func unknownProfileHasNoKeyAndIsNotAnError() throws {
        try withStore { store in
            let missing = try store.key(for: "never-configured")
            #expect(missing == nil)
        }
    }

    @Test func deletingRemovesTheKey() throws {
        try withStore { store in
            try store.store("sk-doomed", for: "deepseek")
            try store.delete(for: "deepseek")
            let afterDelete = try store.key(for: "deepseek")
            #expect(afterDelete == nil)
        }
    }

    /// `deleteAll` backs FR-013's "delete everything". A first version removed
    /// only one item per call — the file-based keychain's `SecItemDelete`
    /// deletes a single match unless asked for all — which left real keys
    /// behind while reporting success. Caught by stray `io.macapy.tests.*`
    /// items surviving a full test run.
    @Test func deleteAllRemovesEveryProfilesKeyNotJustTheFirst() throws {
        let store = KeychainCredentialStore(service: "io.macapy.tests.\(UUID().uuidString)")
        defer { try? store.deleteAll() }
        try store.store("sk-a", for: "deepseek")
        try store.store("sk-b", for: "openai")
        try store.store("sk-c", for: "openrouter")

        try store.deleteAll()

        let remaining = try ["deepseek", "openai", "openrouter"].compactMap { try store.key(for: $0) }
        #expect(remaining.isEmpty, "every key under the service must be gone")
    }

    @Test func deletingAKeyThatIsNotThereIsANoOp() throws {
        try withStore { store in
            try store.delete(for: "never-configured")
        }
    }
}
