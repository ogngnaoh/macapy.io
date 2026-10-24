import Foundation
import PersistKit
import ProviderKit
import Testing
@testable import AppShell

@MainActor struct ProviderPreferencesResetTests {
    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(condition())
    }

    @Test func resetDrainsAnAlreadyStartedWriteAndRejectsEveryNewMutation() async throws {
        let gate = PreferencesResetGate(), store = DelayedProviderPreferences(), credentials = InMemoryCredentialStore(keys: ["deepseek": "synthetic-key"])
        var notifications: [ProviderSettingsChange] = []
        let provider = ResetConnectionProbe()
        let model = ProviderSettingsModel(credentials: credentials, settingsStore: store, ledger: nil,
            connectionTestProvider: provider, onSettingsChange: { _, change in notifications.append(change) })
        await model.load()
        await store.delayNextWrite(gate)
        let oldWrite = Task { await model.setCap(0.34) }
        await gate.waitForArrival()
        var drained = false
        let reset = Task { await model.beginPreferencesReset(); drained = true }
        try await waitUntil { model.isResettingPreferences }
        #expect(!drained)
        #expect(model.settings == ProviderSettings() && model.connectionTest == .idle)
        await model.select(profileID: "deepseek")
        await model.saveKey("replacement", for: "deepseek")
        await model.removeKey(for: "deepseek")
        await model.setModelOverride("late-model", tier: .fast, for: "deepseek")
        await model.setCap(9)
        await model.load()
        await model.testConnection()
        #expect(try credentials.key(for: "deepseek") == "synthetic-key")
        #expect(provider.calls == 0)
        #expect(await store.writeCount == 1)
        await gate.release()
        await oldWrite.value; await reset.value
        #expect(drained && notifications.isEmpty)
        // The coordinator performs the actual namespace clear only after drain.
        await store.clear()
        try credentials.delete(for: "deepseek")
        await model.endPreferencesReset()
        #expect(!model.isResettingPreferences)
        #expect(model.settings == ProviderSettings() && !model.hasKey(for: "deepseek"))
        #expect(notifications == [.transport])
        #expect(await store.providerSettings() == ProviderSettings())
    }

    @Test func delayedLoadCannotRepopulateTheClearedUIAndReloadHoldsAdmissionClosed() async throws {
        let gate = PreferencesResetGate(), store = DelayedProviderPreferences()
        await store.seed(.init(selectedProfileID: "deepseek"))
        await store.delayNextRead(gate)
        var callbackSawClosedAdmission = false
        var model: ProviderSettingsModel!
        model = ProviderSettingsModel(credentials: InMemoryCredentialStore(keys: [:]), settingsStore: store, ledger: nil,
            onSettingsChange: { _, _ in
                callbackSawClosedAdmission = model.isResettingPreferences
                await model.setCap(9)
            })
        let load = Task { await model.load() }
        await gate.waitForArrival()
        let reset = Task { await model.beginPreferencesReset() }
        try await waitUntil { model.isResettingPreferences }
        await gate.release()
        await load.value; await reset.value
        #expect(model.settings.selectedProfileID == nil)
        await store.clear()
        await model.endPreferencesReset()
        #expect(callbackSawClosedAdmission)
        #expect(model.settings == ProviderSettings())
        #expect(await store.writeCount == 0)
    }

    @Test func resetCancelsAConnectionAndRejectsItsLateResult() async throws {
        let provider = ResetConnectionProbe(), store = DelayedProviderPreferences()
        await store.seed(.init(selectedProfileID: "deepseek"))
        let model = ProviderSettingsModel(credentials: InMemoryCredentialStore(keys: [:]), settingsStore: store, ledger: nil,
            connectionTestProvider: provider)
        await model.load()
        let call = Task { await model.testConnection() }
        try await waitUntil { provider.calls == 1 }
        #expect(model.connectionTest == .running)
        await model.beginPreferencesReset()
        await call.value
        #expect(provider.wasCancelled)
        provider.finish()
        await model.testConnection()
        #expect(provider.calls == 1 && model.connectionTest == .idle)
        await store.clear()
        await model.endPreferencesReset()
        #expect(model.connectionTest == .idle && model.settings.selectedProfileID == nil)
    }

    @Test func resetWaitsForDetachedMeterSettlementBeforeTheLedgerCanBeCleared() async throws {
        let gate = PreferencesResetGate(), ledger = DelayedConnectionLedger(gate: gate)
        let store = DelayedProviderPreferences(), provider = ResetConnectionProbe()
        await store.seed(.init(selectedProfileID: "deepseek"))
        let model = ProviderSettingsModel(credentials: InMemoryCredentialStore(keys: [:]), settingsStore: store, ledger: ledger,
            connectionTestProvider: provider)
        await model.load()
        let call = Task { await model.testConnection() }
        try await waitUntil { provider.calls == 1 }
        provider.finish()
        await gate.waitForArrival()
        var drained = false
        let reset = Task { await model.beginPreferencesReset(); drained = true }
        try await waitUntil { model.isResettingPreferences }
        #expect(!drained && model.spendEntries.isEmpty)
        await gate.release()
        await reset.value; await call.value
        #expect(await ledger.entries.count == 1)
        await ledger.clear(); await store.clear()
        await model.endPreferencesReset()
        #expect(await ledger.entries.isEmpty)
        #expect(model.connectionTest == .idle && model.spendEntries.isEmpty)
    }
}

private actor PreferencesResetGate {
    private var arrived = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var hold: CheckedContinuation<Void, Never>?
    func waitForArrival() async { if !arrived { await withCheckedContinuation { waiters.append($0) } } }
    func pause() async {
        arrived = true
        waiters.forEach { $0.resume() }; waiters = []
        if !released { await withCheckedContinuation { hold = $0 } }
    }
    func release() { released = true; hold?.resume(); hold = nil }
}

private actor DelayedProviderPreferences: ProviderPreferencesStoring {
    private var stored = ProviderSettings()
    private var readGate: PreferencesResetGate?
    private var writeGate: PreferencesResetGate?
    private(set) var writeCount = 0
    func seed(_ settings: ProviderSettings) { stored = settings }
    func delayNextWrite(_ gate: PreferencesResetGate) { writeGate = gate }
    func delayNextRead(_ gate: PreferencesResetGate) { readGate = gate }
    func clear() { stored = ProviderSettings() }
    func providerSettings() async -> ProviderSettings {
        let value = stored, gate = readGate; readGate = nil
        await gate?.pause()
        return value
    }
    func pricing() async -> PricingTable { .defaults }
    func setProviderSettings(_ settings: ProviderSettings) async {
        writeCount += 1
        let gate = writeGate; writeGate = nil
        await gate?.pause()
        // Deliberately ignores cancellation: drain must finish this write.
        stored = settings
    }
}

private actor DelayedConnectionLedger: SpendLedger {
    let gate: PreferencesResetGate
    private(set) var entries: [SpendEntry] = []
    init(gate: PreferencesResetGate) { self.gate = gate }
    func record(_ entry: SpendEntry) async { await gate.pause(); entries.append(entry) }
    func totalCostUSD(meetingID: UUID) -> Double { entries.compactMap(\.estCostUSD).reduce(0, +) }
    func clear() { entries = [] }
}

private final class ResetConnectionProbe: LLMProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<LLMEvent, Error>.Continuation?
    private var count = 0
    private var cancelled = false
    var calls: Int { lock.withLock { count } }
    var wasCancelled: Bool { lock.withLock { cancelled } }
    func stream(_ request: CompletionRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            lock.withLock { self.continuation = continuation; count += 1 }
            continuation.onTermination = { [weak self] reason in
                if case .cancelled = reason { self?.lock.withLock { self?.cancelled = true } }
            }
        }
    }
    func finish() {
        let sink = lock.withLock { continuation }
        sink?.yield(.token("OK"))
        sink?.yield(.completed(.init(finishReason: "stop", usage: .init(promptTokens: 8, completionTokens: 1))))
        sink?.finish()
    }
    func completeReportingUsage<T: Decodable>(_ request: CompletionRequest, as type: T.Type) async throws -> CompletedCall<T> {
        throw CancellationError()
    }
}
