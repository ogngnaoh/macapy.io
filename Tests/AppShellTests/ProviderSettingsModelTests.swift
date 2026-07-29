import Foundation
import PersistKit
import ProviderKit
import ProviderTestSupport
import Testing

@testable import AppShell

/// The Providers/Spend screens' logic, minus SwiftUI: which profiles read as
/// configured, what "test connection" reports, and that selecting a provider
/// survives a relaunch. The visual side is author-walked (live checks 9–10).
@MainActor
struct ProviderSettingsModelTests {

    private func model(
        server: FakeOpenAIServer? = nil,
        keys: [String: String] = [:],
        ledger: InMemorySpendLedger = InMemorySpendLedger(),
        settingsStore: SettingsStore? = nil
    ) throws -> ProviderSettingsModel {
        let profiles: [EndpointProfile] = [
            server.map { .fake(baseURL: $0.baseURL) } ?? .deepSeek,
            .ollama,
        ]
        return ProviderSettingsModel(
            profiles: profiles,
            credentials: InMemoryCredentialStore(keys: keys),
            settingsStore: try settingsStore ?? SettingsStore(database: MacapyDatabase.inMemory()),
            ledger: ledger
        )
    }

    private static var okReply: FakeOpenAIServer.Response {
        .sse(frames: [
            OpenAIFixtures.contentDelta("OK"),
            OpenAIFixtures.finish(reason: "stop", promptTokens: 8, completionTokens: 1),
            OpenAIFixtures.done,
        ])
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
