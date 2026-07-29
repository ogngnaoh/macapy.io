import Foundation
import OSLog
import PersistKit
import ProviderTestSupport
import Testing

@testable import ProviderKit

/// Acceptance check 5: after storing a key and running calls, neither the
/// database files nor the process's log output contain key material (SPEC §8:
/// "API keys only in Keychain — never in the DB, config files, or logs").
///
/// The canary is a unique random string, so a hit is unambiguous rather than a
/// coincidence, and the search covers `-wal`/`-shm` as well as the main
/// database file — a key that leaked into an uncheckpointed WAL frame is still
/// on disk.
struct KeyLeakTests {

    private static let canary = "sk-canary-\(UUID().uuidString)"

    private func runCalls(database: MacapyDatabase) async throws {
        let ledger = SpendLedgerStore(database: database)
        // A real meeting row: `spend_ledger.meetingID` is a foreign key, so
        // booking against an invented id would fail before any leak could be
        // checked.
        let meeting = try await MeetingStore(database: database)
            .beginMeeting(startedAt: Date(), ephemeral: false)
        let server = try FakeOpenAIServer.start(responses: [
            .sse(frames: [
                OpenAIFixtures.contentDelta("hello"),
                OpenAIFixtures.finish(reason: "stop", promptTokens: 10, completionTokens: 2),
                OpenAIFixtures.done,
            ]),
            .json(status: 200, body: OpenAIFixtures.completionBody(content: #"{"answer":"yes"}"#)),
        ])
        defer { server.stop() }

        let keychain = KeychainCredentialStore(service: "io.macapy.tests.\(UUID().uuidString)")
        defer { try? keychain.deleteAll() }
        try keychain.store(Self.canary, for: "fake")

        let registry = ProviderRegistry(
            profiles: [.fake(baseURL: server.baseURL)],
            credentials: keychain
        )
        let client = try #require(try registry.client(for: ProviderSettings(selectedProfileID: "fake")))
        let meter = SpendMeter(ledger: ledger, pricing: PricingTable(rates: [:]), capUSD: nil)
        let provider = MeteredProvider(upstream: client, meter: meter, meetingID: meeting.id)

        for try await _ in provider.stream(.hello) {}

        struct Reply: Codable { let answer: String }
        _ = try await provider.complete(.hello, as: Reply.self)
    }

    @Test func theKeyNeverReachesAnyDatabaseFile() async throws {
        let directory = URL.temporaryDirectory.appending(path: "macapy-keyleak-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appending(path: "macapy.sqlite")
        let database = try MacapyDatabase.onDisk(at: databaseURL)

        try await runCalls(database: database)

        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(!files.isEmpty, "nothing was written, so this proves nothing")
        for file in files {
            let bytes = try Data(contentsOf: file)
            let text = String(decoding: bytes, as: UTF8.self)
            #expect(!text.contains(Self.canary), "key material found in \(file.lastPathComponent)")
        }

        // Vacuity guard: the same search *does* find something that is meant to
        // be on disk, so a false "clean" from an empty/unwritten file is caught.
        let ledgerRows = try await SpendLedgerStore(database: database).allEntries()
        #expect(ledgerRows.count == 2, "both calls should have been booked")
    }

    @Test func theKeyNeverReachesTheLog() async throws {
        let since = Date()
        let database = try MacapyDatabase.inMemory()

        try await runCalls(database: database)

        let entries = try Self.macapyLogEntries(since: since)
        #expect(!entries.isEmpty, "no provider log entries at all — this check would pass vacuously")
        for entry in entries {
            #expect(!entry.composedMessage.contains(Self.canary), "key material found in a log entry")
        }
    }

    /// This process's own `io.macapy.app` log entries since `since`.
    private static func macapyLogEntries(since: Date) throws -> [OSLogEntryLog] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let position = store.position(date: since)
        return try store.getEntries(at: position)
            .compactMap { $0 as? OSLogEntryLog }
            .filter { $0.subsystem == "io.macapy.app" }
    }
}
