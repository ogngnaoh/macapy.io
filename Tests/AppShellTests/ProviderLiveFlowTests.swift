import Foundation
import PersistKit
import ProviderKit
import ProviderTestSupport
import Security
import Testing

@testable import AppShell

/// Automated stand-in for the formerly author-walked live checks 9 and 10
/// (slice-02 note 31): the whole settings-model flow — save key, test
/// connection, spend booking, remove key — against the real Keychain, a real
/// on-disk database, and the real DeepSeek endpoint. What stays manual is only
/// the pixels: one visual pass when the app is complete.
///
/// Two oracle rules keep this a check rather than a status report:
/// - Keychain state is judged by a raw `SecItemCopyMatching` query written
///   here, never by asking the `CredentialStore` under test.
/// - The est-cost is recomputed from the pinned DeepSeek rates with local
///   arithmetic, never by calling `PricingTable`.
///
/// Uses a dedicated service so a run can never touch the author's real
/// credentials under `io.macapy.app` — the mechanism is identical, the service
/// string is the only variable, and the production constant is wired in
/// `AppShellCoordinator` via the store's default init.
@Suite(.enabled(if: LiveCredentials.hasDeepSeek))
@MainActor
struct ProviderLiveFlowTests {

    private static let service = "io.macapy.test.live-flow"
    private static let account = "deepseek"

    @Test func keyLifecycleSpendBookingAndNoDiskResidue() async throws {
        let key = try #require(LiveCredentials.deepSeekKey)

        let dbDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macapy-live-flow-\(UUID().uuidString)")
        let credentials = KeychainCredentialStore(service: Self.service)
        defer {
            try? credentials.deleteAll()
            try? FileManager.default.removeItem(at: dbDir)
        }

        let database = try MacapyDatabase.onDisk(at: dbDir.appendingPathComponent("live.sqlite"))
        let model = ProviderSettingsModel(
            credentials: credentials,
            settingsStore: SettingsStore(database: database),
            ledger: SpendLedgerStore(database: database)
        )
        await model.load()

        // Check 9 — saving lands the key in the actual Keychain.
        await model.saveKey(key, for: Self.account)
        #expect(rawKeychainValue() == key, "the raw Security query must see the exact key bytes")
        #expect(model.hasKey(for: Self.account))

        // Check 9 — test connection streams a reply from the real endpoint.
        await model.testConnection()
        guard case .succeeded(let reply) = model.connectionTest else {
            Issue.record("test connection did not succeed: \(model.connectionTest)")
            return
        }
        #expect(!reply.isEmpty, "the succeeded state must carry the streamed reply")

        // Check 10 — the call was booked: one classifier row, real usage, and
        // an est-cost matching the pinned v4-flash rates (2026-07-29:
        // 0.14 / 0.0028 / 0.28 per million), recomputed independently here.
        #expect(model.spendEntries.count == 1, "exactly the test connection should be booked")
        let entry = try #require(model.spendEntries.first)
        #expect(entry.model == "deepseek-v4-flash")
        #expect(entry.purpose == .classifier)
        #expect(entry.usage.promptTokens > 0)
        #expect(entry.usage.completionTokens > 0)
        let million = 1_000_000.0
        let expectedUSD = Double(entry.usage.promptTokens - entry.usage.cachedTokens) / million * 0.14
            + Double(entry.usage.cachedTokens) / million * 0.0028
            + Double(entry.usage.completionTokens) / million * 0.28
        let bookedUSD = try #require(entry.estCostUSD, "a v4-flash row must never book unpriced")
        #expect(abs(bookedUSD - expectedUSD) < 1e-12,
                "booked \(bookedUSD) but the pinned rates give \(expectedUSD)")

        // Check 9 — "nowhere on disk": every byte this flow wrote (main db,
        // WAL, shm) is free of key material.
        for file in try FileManager.default.contentsOfDirectory(
            at: dbDir, includingPropertiesForKeys: nil
        ) {
            let bytes = try Data(contentsOf: file)
            #expect(bytes.range(of: Data(key.utf8)) == nil,
                    "key material on disk in \(file.lastPathComponent)")
        }

        // Check 9 — removing deletes the Keychain item, seen by the raw query.
        await model.removeKey(for: Self.account)
        #expect(rawKeychainValue() == nil, "the item must be gone after in-app Remove")
        #expect(model.hasKey(for: Self.account) == false)
        #expect(model.isConfigured == false, "no key means the quiet setup prompt, not an error")
    }

    /// The independent oracle: a raw Keychain read that shares no code with
    /// `KeychainCredentialStore`.
    private func rawKeychainValue() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
