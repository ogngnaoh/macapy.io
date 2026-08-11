import Foundation
import PersistKit
import ProviderKit
import ProviderTestSupport
import Testing

@testable import AppShell

private struct ScriptedConnectionProvider: LLMProvider {
    let events: [LLMEvent]

    func stream(_ request: CompletionRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }

    func completeReportingUsage<T: Decodable>(
        _ request: CompletionRequest,
        as type: T.Type
    ) async throws -> CompletedCall<T> {
        throw ProviderError.malformedResponse("unused scripted structured call")
    }
}

private struct WaitingConnectionProvider: LLMProvider {
    func stream(_ request: CompletionRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await Task.sleep(for: .seconds(30))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func completeReportingUsage<T: Decodable>(
        _ request: CompletionRequest,
        as type: T.Type
    ) async throws -> CompletedCall<T> {
        throw ProviderError.malformedResponse("unused waiting structured call")
    }
}

/// The Providers/Spend screens' logic, minus SwiftUI: which profiles read as
/// configured, what "test connection" reports, and that selecting a provider
/// survives a relaunch. The visual side is author-walked (live checks 9–10).
@MainActor
struct ProviderSettingsModelTests {

    private func model(
        server: FakeOpenAIServer? = nil,
        keys: [String: String] = [:],
        ledger: (any SpendLedger)? = InMemorySpendLedger(),
        settingsStore: SettingsStore? = nil,
        connectionTestProvider: (any LLMProvider)? = nil
    ) throws -> ProviderSettingsModel {
        let profiles: [EndpointProfile] = [
            server.map { .fake(baseURL: $0.baseURL) } ?? .deepSeek,
            .ollama,
        ]
        return ProviderSettingsModel(
            profiles: profiles,
            credentials: InMemoryCredentialStore(keys: keys),
            settingsStore: try settingsStore ?? SettingsStore(database: MacapyDatabase.inMemory()),
            ledger: ledger,
            connectionTestProvider: connectionTestProvider
        )
    }

    private static var okReply: FakeOpenAIServer.Response {
        .sse(frames: [
            OpenAIFixtures.contentDelta("OK"),
            OpenAIFixtures.finish(reason: "stop", promptTokens: 8, completionTokens: 1),
            OpenAIFixtures.done,
        ])
    }

    // MARK: - Wired providers

    /// Author ruling 2026-08-06 (slice-2 note 30): the app exposes DeepSeek and
    /// nothing else until another profile is live-verified. The catalog
    /// (`builtIns`) survives in ProviderKit for the fast-follow; this pins the
    /// default the app shell actually constructs with.
    @Test func theAppWiresOnlyDeepSeek() throws {
        let model = ProviderSettingsModel(
            credentials: InMemoryCredentialStore(keys: [:]),
            settingsStore: try SettingsStore(database: MacapyDatabase.inMemory()),
            ledger: InMemorySpendLedger()
        )

        #expect(model.profiles.map(\.id) == ["deepseek"],
                "an unwired provider row is an invitation into a path no live check has touched")
    }

    // MARK: - Configuration state

    @Test func afreshInstallReportsNoProviderConfigured() async throws {
        let model = try model()

        await model.load()

        #expect(model.settings.selectedProfileID == nil)
        #expect(model.isConfigured == false, "AI surfaces must show the quiet setup prompt, not an error")
    }

    @Test func savingAKeyMarksThatProfileConfigured() async throws {
        let model = try model()

        await model.load()
        await model.saveKey("sk-new", for: "deepseek")

        #expect(model.hasKey(for: "deepseek"))
        #expect(model.hasKey(for: "ollama") == false)
    }

    @Test func removingAKeyClearsItAndTheSelectionFallsBackToUnconfigured() async throws {
        let model = try model(keys: ["deepseek": "sk-old"])

        await model.load()
        await model.select(profileID: "deepseek")
        await model.removeKey(for: "deepseek")

        #expect(model.hasKey(for: "deepseek") == false)
        #expect(model.isConfigured == false, "a selected profile with no key is not configured")
    }

    @Test func aKeylessLocalProviderCountsAsConfiguredOnceSelected() async throws {
        let model = try model()

        await model.load()
        await model.select(profileID: "ollama")

        #expect(model.isConfigured, "Ollama needs no key")
    }

    // MARK: - Spend tab data path (slice-2 verifier finding V1)

    /// `refreshSpend` silently no-ops unless the injected ledger is the real
    /// `SpendLedgerStore` — every other test here injects `InMemorySpendLedger`,
    /// so without this test the Spend tab's actual data path had zero coverage:
    /// a broken downcast would show "No AI calls yet" forever with the suite
    /// green.
    @Test func spendEntriesLoadThroughTheRealLedgerStore() async throws {
        let store = SpendLedgerStore(database: try MacapyDatabase.inMemory())
        try await store.record(SpendEntry(
            id: UUID(),
            meetingID: nil,
            model: "fake-model",
            usage: TokenUsage(promptTokens: 10, completionTokens: 2),
            estCostUSD: 0.01,
            purpose: .classifier,
            at: Date()
        ))
        let model = ProviderSettingsModel(
            profiles: [.deepSeek],
            credentials: InMemoryCredentialStore(keys: [:]),
            settingsStore: try SettingsStore(database: MacapyDatabase.inMemory()),
            ledger: store
        )

        await model.load()

        #expect(model.spendEntries.count == 1,
                "the Spend tab must render rows from the production store type")
        #expect(model.spendEntries.first?.model == "fake-model")
    }

    @Test func theSelectedProviderSurvivesAReload() async throws {
        let store = SettingsStore(database: try MacapyDatabase.inMemory())
        let first = try model(keys: ["deepseek": "sk-1"], settingsStore: store)
        await first.load()
        await first.select(profileID: "deepseek")

        let second = try model(keys: ["deepseek": "sk-1"], settingsStore: store)
        await second.load()

        #expect(second.settings.selectedProfileID == "deepseek")
    }

    @Test func theCapSurvivesAReload() async throws {
        let store = SettingsStore(database: try MacapyDatabase.inMemory())
        let first = try model(settingsStore: store)
        await first.load()
        await first.setCap(0.25)

        let second = try model(settingsStore: store)
        await second.load()

        #expect(second.settings.perMeetingCapUSD == 0.25)
    }

    // MARK: - Test connection

    @Test func testConnectionReportsTheStreamedReply() async throws {
        let server = try FakeOpenAIServer.start(responses: [Self.okReply])
        defer { server.stop() }
        let model = try model(server: server, keys: ["fake": "sk-test"])
        await model.load()
        await model.select(profileID: "fake")

        await model.testConnection()

        guard case .succeeded(let text) = model.connectionTest else {
            Issue.record("expected success, got \(model.connectionTest)")
            return
        }
        #expect(text.contains("OK"))
    }

    @Test func testConnectionRejectsAnEmptyNaturalStopInsteadOfClaimingConnected() async throws {
        let server = try FakeOpenAIServer.start(responses: [
            .sse(frames: [
                OpenAIFixtures.finish(reason: "stop", promptTokens: 8, completionTokens: 0),
                OpenAIFixtures.done,
            ])
        ])
        defer { server.stop() }
        let model = try model(server: server, keys: ["fake": "sk-test"])
        await model.load()
        await model.select(profileID: "fake")

        await model.testConnection()

        guard case .failed(let message) = model.connectionTest else {
            Issue.record("an empty reply must not be reported as connected: \(model.connectionTest)")
            return
        }
        #expect(message == ProviderError.malformedResponse("ignored").userMessage)
    }

    @Test(arguments: ["length", "content_filter", "provider-secret-terminal"])
    func testConnectionRejectsEveryNonStopTerminalAndClearsPartialReply(reason: String) async throws {
        let partial = "SECRET_PARTIAL_REPLY"
        let server = try FakeOpenAIServer.start(responses: [
            .sse(frames: [
                OpenAIFixtures.contentDelta(partial),
                OpenAIFixtures.finish(
                    reason: reason,
                    promptTokens: 8,
                    completionTokens: 3
                ),
                OpenAIFixtures.done,
            ])
        ])
        defer { server.stop() }
        let ledger = InMemorySpendLedger()
        let model = try model(
            server: server,
            keys: ["fake": "sk-test"],
            ledger: ledger
        )
        await model.load()
        await model.select(profileID: "fake")

        await model.testConnection()

        guard case .failed(let message) = model.connectionTest else {
            Issue.record("non-stop terminal must fail: \(model.connectionTest)")
            return
        }
        #expect(message == ProviderError.truncated(finishReason: "unknown").userMessage)
        #expect(!message.contains(partial))
        #expect(!message.contains(reason))
        #expect(await ledger.entries.count == 1,
                "the stream must be drained through metering before its terminal disposition is rejected")
    }

    @Test func testConnectionRejectsAStreamWithoutATerminalAndClearsPartialReply() async throws {
        let partial = "SECRET_PARTIAL_REPLY"
        let provider = ScriptedConnectionProvider(events: [.token(partial)])
        let model = try model(
            keys: ["deepseek": "sk-test"],
            ledger: nil,
            connectionTestProvider: provider
        )
        await model.load()
        await model.select(profileID: "deepseek")

        await model.testConnection()

        guard case .failed(let message) = model.connectionTest else {
            Issue.record("missing terminal must fail: \(model.connectionTest)")
            return
        }
        #expect(message == ProviderError.malformedResponse("ignored").userMessage)
        #expect(!message.contains(partial))
    }

    @Test func testConnectionRejectsDuplicateTerminalsAndNeverPublishesPartialReply() async throws {
        let partial = "SECRET_PARTIAL_REPLY"
        let provider = ScriptedConnectionProvider(events: [
            .token(partial),
            .completed(.init(finishReason: "stop", usage: nil)),
            .completed(.init(finishReason: "stop", usage: nil)),
        ])
        let model = try model(
            keys: ["deepseek": "sk-test"],
            ledger: nil,
            connectionTestProvider: provider
        )
        await model.load()
        await model.select(profileID: "deepseek")

        await model.testConnection()

        guard case .failed(let message) = model.connectionTest else {
            Issue.record("duplicate terminal must fail: \(model.connectionTest)")
            return
        }
        #expect(message == ProviderError.malformedResponse("ignored").userMessage)
        #expect(!message.contains(partial))
    }

    @Test func cancellingTestConnectionReturnsQuietlyToIdle() async throws {
        let model = try model(
            keys: ["deepseek": "sk-test"],
            ledger: nil,
            connectionTestProvider: WaitingConnectionProvider()
        )
        await model.load()
        await model.select(profileID: "deepseek")

        let call = Task { await model.testConnection() }
        await Task.yield()
        call.cancel()
        await call.value

        #expect(model.connectionTest == .idle)
    }

    @Test func testConnectionReportsAPlainMessageWhenTheKeyIsRejected() async throws {
        let server = try FakeOpenAIServer.start(responses: [
            .json(status: 401, body: OpenAIFixtures.errorBody(message: "Invalid API key"))
        ])
        defer { server.stop() }
        let model = try model(server: server, keys: ["fake": "sk-wrong"])
        await model.load()
        await model.select(profileID: "fake")

        await model.testConnection()

        guard case .failed(let message) = model.connectionTest else {
            Issue.record("expected failure, got \(model.connectionTest)")
            return
        }
        #expect(message.contains("key"), "the message should name the cause, not dump an error type")
    }

    @Test func testConnectionWithNoProviderConfiguredSaysSoInsteadOfCallingOut() async throws {
        let model = try model()
        await model.load()

        await model.testConnection()

        guard case .failed(let message) = model.connectionTest else {
            Issue.record("expected failure, got \(model.connectionTest)")
            return
        }
        #expect(message.lowercased().contains("provider") || message.lowercased().contains("key"))
    }

    @Test func testConnectionIsBookedInTheLedgerOutsideAnyMeeting() async throws {
        let server = try FakeOpenAIServer.start(responses: [Self.okReply])
        defer { server.stop() }
        let ledger = InMemorySpendLedger()
        let model = try model(server: server, keys: ["fake": "sk-test"], ledger: ledger)
        await model.load()
        await model.select(profileID: "fake")

        await model.testConnection()

        let entries = await ledger.entries
        #expect(entries.count == 1)
        #expect(entries.first?.meetingID == nil, "there is no meeting yet — the row still belongs in the ledger")
    }
}
