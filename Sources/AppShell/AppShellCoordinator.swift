import AgentKit
import CaptureKit
import DiarizeKit
import Foundation
import Observation
import PersistKit
import ProviderKit
import TranscribeKit
import os

/// App-lifetime owner of the shell's moving parts. All session mutations flow
/// through `syncPanel()` so panel visibility, the transcript pipeline, and
/// session state stay in lockstep. `@Observable` so the menu bar's "Ephemeral
/// meeting" toggle re-renders when flipped (`session`/`store` were already
/// separately `@Observable`; this just extends the same tracking to the
/// coordinator's own state).
@MainActor
@Observable
final class AppShellCoordinator {
    let session = SessionController()
    /// App-lifetime, stable identity (the panel's hosting view is cached, so the
    /// observed object must not be swapped out).
    let store = TranscriptStore()
    let activationPolicy = ActivationPolicyController()
    /// App-lifetime identity injected into the cached panel root. Its contents
    /// are reset per meeting and never persisted.
    let copilot = LiveCopilotModel()

    /// Menu-bar "Ephemeral meeting" toggle: applies to the *next* meeting
    /// started, not one already running (slice-04 doc decision 9).
    var ephemeralNextMeeting = false

    @ObservationIgnored private let panel: PanelPresenting
    @ObservationIgnored private let makePipeline: @MainActor (TranscriptStore) -> MeetingPipeline
    @ObservationIgnored private let makeDatabase: @MainActor () throws -> MacapyDatabase
    @ObservationIgnored private let providerProfiles: [EndpointProfile]
    @ObservationIgnored private let credentials: any CredentialStore
    /// Test seam for lifecycle tests that must hold a real provider response
    /// between extraction and persistence. Production always leaves this nil.
    @ObservationIgnored private let postMeetingContextOverride:
        (@Sendable (UUID) async throws -> PostMeetingProviderContext?)?
    /// Focused lifecycle-test seams. Production always resolves its upstream
    /// provider and ledger from settings/persistence.
    @ObservationIgnored private let liveProviderOverride: (any LLMProvider)?
    @ObservationIgnored private let liveSpendLedgerOverride: (any SpendLedger)?
    @ObservationIgnored private var cachedDatabase: MacapyDatabase?
    @ObservationIgnored private var cachedPersistentStore: MeetingStore?
    @ObservationIgnored private var cachedSettingsStore: SettingsStore?
    @ObservationIgnored private var cachedSpendLedger: SpendLedgerStore?
    @ObservationIgnored private var cachedArtifactStore: ArtifactStore?
    @ObservationIgnored private var cachedSearchStore: SearchStore?
    @ObservationIgnored private var cachedHistorySearchModel: HistorySearchModel?
    @ObservationIgnored private var cachedPostMeetingAgent: PostMeetingAgent?
    @ObservationIgnored private var cachedProviderSettingsModel: ProviderSettingsModel?
    @ObservationIgnored private var cachedLiveAISettingsModel: LiveAISettingsModel?
    @ObservationIgnored private let meetingSpendRegistry = MeetingSpendRegistry()
    @ObservationIgnored private var hotKey: HotKey?
    @ObservationIgnored private var pauseHotKey: HotKey?
    @ObservationIgnored private var catchUpHotKey: HotKey?
    @ObservationIgnored private var askHotKey: HotKey?
    @ObservationIgnored private var dismissCopilotHotKey: HotKey?
    @ObservationIgnored private var pipeline: MeetingPipeline?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var stopTask: Task<Void, Never>?
    @ObservationIgnored private var pauseResumeTask: Task<Void, Never>?
    @ObservationIgnored private var artifactGenerationTask: Task<Void, Never>?
    @ObservationIgnored private var copilotTurnsTask: Task<Void, Never>?
    @ObservationIgnored private var activeCopilotMeetingID: UUID?
    @ObservationIgnored private let log = Logger(subsystem: "io.macapy.app", category: "AppShell")

    /// Production wiring: real mic + system-audio capture, SpeechAnalyzer, and
    /// an on-disk GRDB store under `~/Library/Application Support/macapy/`.
    /// Injected apart so tests can drive the shell with fakes, no panel, no
    /// global hotkeys, and no real disk access.
    ///
    /// `makeDatabase` has no default on purpose: a defaulted production store
    /// let a test silently write into the real on-disk database (M1 close-out
    /// defect). Every caller — the app's composition root included — must
    /// choose its database explicitly. It vends the *database* rather than a
    /// `MeetingStore` because slice 2 added two more stores over the same
    /// connection (settings, spend ledger), and they must not each open their
    /// own.
    /// `providerProfiles`/`credentials` default to production (the wired
    /// catalog, the real Keychain) — safe to default, unlike `makeDatabase`:
    /// neither performs I/O until a provider is actually configured, so an
    /// unconfigured test coordinator never touches the user's Keychain.
    /// Tests that exercise the agent inject a fake-server profile and an
    /// in-memory store here.
    init(
        panel: PanelPresenting = FloatingPanelController(),
        installHotKey: Bool = true,
        makePipeline: @escaping @MainActor (TranscriptStore) -> MeetingPipeline = AppShellCoordinator.productionPipeline,
        makeDatabase: @escaping @MainActor () throws -> MacapyDatabase,
        providerProfiles: [EndpointProfile] = EndpointProfile.wired,
        credentials: any CredentialStore = KeychainCredentialStore(),
        postMeetingContextOverride:
            (@Sendable (UUID) async throws -> PostMeetingProviderContext?)? = nil,
        liveProviderOverride: (any LLMProvider)? = nil,
        liveSpendLedgerOverride: (any SpendLedger)? = nil
    ) {
        self.panel = panel
        self.makePipeline = makePipeline
        self.makeDatabase = makeDatabase
        self.providerProfiles = providerProfiles
        self.credentials = credentials
        self.postMeetingContextOverride = postMeetingContextOverride
        self.liveProviderOverride = liveProviderOverride
        self.liveSpendLedgerOverride = liveSpendLedgerOverride
        if installHotKey {
            hotKey = HotKey.startStopMeeting { [weak self] in
                self?.toggleSession()
            }
            pauseHotKey = HotKey.pauseResumeMeeting { [weak self] in
                self?.togglePause()
            }
            catchUpHotKey = HotKey.catchUp { [weak self] in
                self?.requestCatchUp()
            }
            askHotKey = HotKey.askCopilot { [weak self] in
                self?.requestAsk()
            }
            dismissCopilotHotKey = HotKey.dismissCopilot { [weak self] in
                self?.requestDismissCopilot()
            }
        }
    }

    static func productionPipeline(_ store: TranscriptStore) -> MeetingPipeline {
        // Two capture sources: mic (You) + system-audio process tap (Them). Both
        // feed the one engine's per-source transcribe() calls into the shared
        // store, which interleaves by tStart. Fakes are injected in tests via the
        // makePipeline closure, so this production wiring is test-inert.
        //
        // Diarization rides only when its models are installed (slice-4
        // decision 6): the availability check happens at meeting start, so
        // the meeting after a consent-gated download picks it up with no
        // restart; with no models the pipeline is exactly M1 — zero network.
        var makeDiarizer: (@Sendable () throws -> DiarizationSession)?
        if DiarizationModelStore.isInstalled {
            makeDiarizer = { @Sendable in DiarizationSession(engine: try FluidAudioDiarizer()) }
        }
        return MeetingPipeline(
            engine: SpeechAnalyzerEngine(),
            sources: [MicCapture(), SystemAudioCapture()],
            store: store,
            makeDiarizer: makeDiarizer)
    }

    /// The production on-disk database (SPEC §5): `~/Library/Application
    /// Support/macapy/macapy.sqlite`. Creates the containing directory on
    /// first use; test wiring never calls this (see `makeDatabase`).
    static func productionDatabase() throws -> MacapyDatabase {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let dbURL = appSupport
            .appendingPathComponent("macapy", isDirectory: true)
            .appendingPathComponent("macapy.sqlite")
        return try MacapyDatabase.onDisk(at: dbURL)
    }

    func toggleSession() {
        session.toggle()
        syncPanel()
    }

    /// ⌥⌘P / menu bar: pause a capturing session, or resume a paused one — a
    /// no-op while idle. Session state flips synchronously (so the panel's
    /// Paused header updates immediately); the capture-layer halt runs in the
    /// background (awaited via `settle()` in tests, same pattern as start/stop).
    func togglePause() {
        switch session.state {
        case .capturing:
            session.pause()
            copilot.setAutomaticSuppressed(true)
            let pausing = pipeline
            pauseResumeTask = Task { await pausing?.pause() }
        case .paused:
            session.resume()
            copilot.setAutomaticSuppressed(false)
            let resuming = pipeline
            pauseResumeTask = Task { await resuming?.resume() }
        case .idle:
            break
        }
    }

    func requestCatchUp() { copilot.requestCatchUp() }
    func requestAsk() { copilot.requestAsk() }
    func requestDismissCopilot() { copilot.dismissCard() }

    private func syncPanel() {
        if session.isCapturing {
            panel.show(session: session, store: store, copilot: copilot)
            startPipelineIfNeeded()
        } else {
            log.info("session stopped")
            panel.hide()
            teardownPipeline()
        }
    }

    private func startPipelineIfNeeded() {
        guard pipeline == nil else { return }  // never double-start one session
        log.info("session started")
        let previousStop = stopTask
        let newPipeline = makePipeline(store)
        pipeline = newPipeline
        session.signalMeter = newPipeline.signalMeter
        newPipeline.onFailure = { [weak self] error in
            self?.handleFailure(from: newPipeline, error)
        }
        // Captured now, not read later: the ephemeral toggle applies to the
        // meeting being started, not to whatever the user flips it to next.
        let ephemeral = ephemeralNextMeeting
        startTask = Task { [weak self] in
            // Serialize behind any in-flight teardown so a prior meeting's tail
            // can't leak into the fresh store after reset().
            await previousStop?.value
            guard let self, self.pipeline === newPipeline else { return }
            self.store.reset()
            // turnsStream() is non-replaying. Attach immediately after reset,
            // before settings/database awaits and strictly before start() can
            // prepare capture or emit a turn.
            let turns = self.store.turnsStream()
            self.copilotTurnsTask = Task { @MainActor [weak self] in
                for await turn in turns {
                    guard let self, self.pipeline === newPipeline else { return }
                    self.copilot.receive(
                        turn,
                        userSpeaking: self.store.volatile[.mic] != nil
                    )
                }
            }
            do {
                let mode = try self.resolvePersistenceMode(ephemeral: ephemeral)
                let settingsStore = self.settingsStore()
                let providerSettings = (try? await settingsStore?.providerSettings()) ?? ProviderSettings()
                var liveSettings = (try? await settingsStore?.liveAISettings()) ?? LiveAISettings()
                if liveSettings.preferredName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                    liveSettings.preferredName = LiveAISettingsModel.defaultPreferredName
                }
                let pricing = (try? await settingsStore?.pricing()) ?? PricingTable.defaults
                try await newPipeline.start(mode: mode) { [weak self] meetingID, isEphemeral in
                    guard let self, self.pipeline === newPipeline else { return }
                    await self.configureCopilot(
                        meetingID: meetingID,
                        ephemeral: isEphemeral,
                        providerSettings: providerSettings,
                        liveSettings: liveSettings,
                        pricing: pricing
                    )
                }
            } catch {
                self.handleFailure(from: newPipeline, error)
            }
        }
    }

    /// `.ephemeral` bypasses persistence entirely (a fresh in-memory store per
    /// meeting, built inside `MeetingPipeline.start`). `.persistent` uses the
    /// same lazily-opened, memoized on-disk store as `historyStore()`, so a
    /// pure-ephemeral run (or a test that never goes persistent) never
    /// touches disk at all.
    private func resolvePersistenceMode(ephemeral: Bool) throws -> PersistenceMode {
        guard !ephemeral else { return .ephemeral }
        return .persistent(try openOrReusePersistentStore())
    }

    /// The store backing the History window. Lazily opens (and memoizes) the
    /// on-disk database on first use — same instance a persistent meeting
    /// would write through — so History shows meetings from prior app runs
    /// even before any meeting starts in this one. `nil` (logged) if opening
    /// the database fails; the view shows an error state rather than crashing.
    /// The current (or most recently started) meeting's latency recorder,
    /// for the diagnostics section (slice-05 doc decision 7) — `nil` before
    /// any meeting has ever started. Not `@Observable`-tracked: `LatencyRecorder`
    /// is a plain lock-protected class, so the diagnostics view polls it
    /// instead (see `DiagnosticsSectionView`).
    var currentRecorder: LatencyRecorder? {
        pipeline?.recorder
    }

    /// Signal-strip data source (slice-4 decision 5); nil when no pipeline has
    /// existed yet — the strip falls back to session-state rendering.
    var currentSignalMeter: SignalLevelMeter? {
        pipeline?.signalMeter
    }

    /// Diagnostics "Dropped chunks" tile (slice-4 decision 4).
    var currentDroppedChunks: Int? {
        pipeline?.droppedChunks
    }

    func historyStore() -> MeetingStore? {
        do {
            return try openOrReusePersistentStore()
        } catch {
            log.error("failed to open history store: \(error.localizedDescription)")
            return nil
        }
    }

    private func openOrReusePersistentStore() throws -> MeetingStore {
        if let cachedPersistentStore { return cachedPersistentStore }
        let opened = MeetingStore(database: try openOrReuseDatabase())
        cachedPersistentStore = opened
        return opened
    }

    private func openOrReuseDatabase() throws -> MacapyDatabase {
        if let cachedDatabase { return cachedDatabase }
        let opened = try makeDatabase()
        cachedDatabase = opened
        return opened
    }

    /// Provider configuration + spend, over the same connection as history.
    /// `nil` (logged) if the database can't be opened — Settings then shows an
    /// error state instead of crashing, exactly like History.
    func settingsStore() -> SettingsStore? {
        do {
            if let cachedSettingsStore { return cachedSettingsStore }
            let opened = SettingsStore(database: try openOrReuseDatabase())
            cachedSettingsStore = opened
            return opened
        } catch {
            log.error("failed to open settings store: \(error.localizedDescription)")
            return nil
        }
    }

    /// The settings window's provider/spend state, built once and reused: the
    /// window can be closed and reopened, and a fresh model each time would
    /// drop the last connection-test result and re-read the ledger for nothing.
    func providerSettingsModel() -> ProviderSettingsModel {
        if let cachedProviderSettingsModel { return cachedProviderSettingsModel }
        let model = ProviderSettingsModel(
            profiles: providerProfiles,
            credentials: credentials,
            settingsStore: settingsStore(),
            ledger: spendLedger(),
            onSettingsChange: { [weak self] settings in
                guard let self else { return }
                let activeMeetingID = self.activeCopilotMeetingID
                let capRaised = await self.meetingSpendRegistry.updateCaps(
                    settings.perMeetingCapUSD,
                    activeMeetingID: activeMeetingID
                )
                if capRaised { self.copilot.releaseCapPauseAfterCapIncrease() }
                await self.refreshActiveCopilotProvider(using: settings)
            }
        )
        cachedProviderSettingsModel = model
        return model
    }

    func liveAISettingsModel() -> LiveAISettingsModel {
        if let cachedLiveAISettingsModel { return cachedLiveAISettingsModel }
        let model = LiveAISettingsModel(store: settingsStore()) { [weak self] settings in
            await self?.applyLiveAISettings(settings)
        }
        cachedLiveAISettingsModel = model
        return model
    }

    func spendLedger() -> SpendLedgerStore? {
        do {
            if let cachedSpendLedger { return cachedSpendLedger }
            let opened = SpendLedgerStore(database: try openOrReuseDatabase())
            cachedSpendLedger = opened
            return opened
        } catch {
            log.error("failed to open spend ledger: \(error.localizedDescription)")
            return nil
        }
    }

    /// Draft artifacts, over the same connection as everything else. `nil`
    /// (logged) when the database can't open — meeting detail then shows an
    /// error state, like History and Settings.
    func artifactStore() -> ArtifactStore? {
        do {
            if let cachedArtifactStore { return cachedArtifactStore }
            let opened = ArtifactStore(database: try openOrReuseDatabase())
            cachedArtifactStore = opened
            return opened
        } catch {
            log.error("failed to open artifact store: \(error.localizedDescription)")
            return nil
        }
    }

    /// FTS search over the same connection as history (slice-05 doc decision
    /// 4). `nil` (logged) when the database can't open — the search field
    /// then returns empty groups rather than erroring.
    func searchStore() -> SearchStore? {
        do {
            if let cachedSearchStore { return cachedSearchStore }
            let opened = SearchStore(database: try openOrReuseDatabase())
            cachedSearchStore = opened
            return opened
        } catch {
            log.error("failed to open search store: \(error.localizedDescription)")
            return nil
        }
    }

    /// The History window's model, built once so selection and the active
    /// query survive the window closing and reopening; `load()` re-fetches
    /// on every appearance (fetch-on-appear stays the design).
    func historySearchModel() -> HistorySearchModel? {
        if let cachedHistorySearchModel { return cachedHistorySearchModel }
        guard let meetings = historyStore() else { return nil }
        let model = HistorySearchModel(meetings: meetings, search: searchStore())
        cachedHistorySearchModel = model
        return model
    }

    /// Delete-everything (FR-013, slice-05 doc decision 8): refused while a
    /// meeting is capturing — the live pipeline writes through the same
    /// database, and "capture always wins" is the standing rule. Returns
    /// whether deletion ran. Meeting data only; Keychain and settings
    /// survive (author ruling 2026-08-07).
    @discardableResult
    func deleteAllMeetingData() async -> Bool {
        guard !session.isCapturing else {
            log.error("delete-everything refused: a meeting is capturing")
            return false
        }
        guard let store = historyStore() else { return false }
        do {
            try await store.deleteAllUserData()
        } catch {
            log.error("delete-everything failed: \(error.localizedDescription)")
            return false
        }
        await historySearchModel()?.load()
        return true
    }

    /// The post-meeting agent, wired the only way shipping code builds a
    /// provider: registry-resolved client, wrapped in a `SpendMeter` carrying
    /// `perMeetingCapUSD` (the slice-2 V5 debt — this is the one place a
    /// capped meter is constructed) inside a `MeteredProvider` keyed to the
    /// meeting. Settings are re-read per generation, so a cap changed after
    /// meeting end applies to a retroactive generate. Model overrides remain
    /// stored for compatibility but production ignores them for this MVP.
    func postMeetingAgent() -> PostMeetingAgent? {
        if let cachedPostMeetingAgent { return cachedPostMeetingAgent }
        guard let meetings = historyStore(),
              let artifacts = artifactStore(),
              let settingsStore = settingsStore(),
              let ledger = spendLedger()
        else { return nil }
        let registry = ProviderRegistry(profiles: providerProfiles, credentials: credentials)
        let meterRegistry = meetingSpendRegistry
        let contextOverride = postMeetingContextOverride
        let agent = PostMeetingAgent(meetings: meetings, artifacts: artifacts) { meetingID in
            let settings = try await settingsStore.providerSettings()
            guard (try await settingsStore.liveAISettings()).aiFeaturesEnabled else { return nil }
            if let contextOverride {
                return try await contextOverride(meetingID)
            }
            guard let client = try registry.client(for: settings),
                  let profileID = settings.selectedProfileID,
                  let profile = registry.profile(id: profileID)
            else { return nil }
            let meter: SpendMeter
            if let existing = await meterRegistry.meter(meetingID: meetingID) {
                meter = existing
            } else {
                meter = SpendMeter(
                    ledger: ledger,
                    pricing: try await settingsStore.pricing(),
                    capUSD: settings.perMeetingCapUSD
                )
            }
            return PostMeetingProviderContext(
                provider: MeteredProvider(upstream: client, meter: meter, meetingID: meetingID),
                // Production ignores preserved model overrides for the MVP.
                model: profile.deepModel
            )
        }
        cachedPostMeetingAgent = agent
        return agent
    }

    /// One meeting's detail-pane state. Built per selection (fetch-on-appear,
    /// like History itself); the closures re-read settings on every ask so a
    /// provider or cap configured after the meeting applies immediately.
    func meetingDetailModel(for meeting: MeetingRecord) -> MeetingDetailModel {
        let registry = ProviderRegistry(profiles: providerProfiles, credentials: credentials)
        let settingsStore = settingsStore()
        let ledger = spendLedger()
        return MeetingDetailModel(
            meeting: meeting,
            artifactStore: artifactStore(),
            agent: postMeetingAgent(),
            isProviderConfigured: {
                guard let settingsStore else { return false }
                let settings = (try? await settingsStore.providerSettings()) ?? ProviderSettings()
                return registry.isConfigured(settings)
            },
            capStatus: { meetingID in
                guard let settingsStore, let ledger,
                      let capUSD = (try? await settingsStore.providerSettings())?.perMeetingCapUSD
                else { return nil }
                let spentUSD = (try? await ledger.totalCostUSD(meetingID: meetingID)) ?? 0
                return (spentUSD: spentUSD, capUSD: capUSD)
            }
        )
    }

    private func teardownPipeline() {
        guard let stopping = pipeline else { return }
        pipeline = nil
        stopping.markStopped()  // synchronous: a suspended start() bails at its checkpoint
        let inFlightStart = startTask
        startTask = nil
        // Chain behind the previous teardown so every outstanding stop is
        // serialized. Because a start awaits the *latest* stopTask, and the
        // latest transitively awaits the whole chain, no later start's reset()
        // can run while any earlier pipeline's drain is still writing to the
        // shared store — even with two or more teardowns in flight.
        let previousStop = stopTask
        stopTask = Task { [weak self] in
            inFlightStart?.cancel()
            await previousStop?.value
            // Capture is the critical path: cancel and drain presentation work
            // first, but never wait here for detached spend settlement.
            await self?.copilot.stopMeetingAndWait()
            self?.copilotTurnsTask?.cancel()
            self?.copilotTurnsTask = nil
            let liveMeetingID = self?.activeCopilotMeetingID
            let liveMeter: SpendMeter?
            if let liveMeetingID, let self {
                liveMeter = await self.meetingSpendRegistry.meter(meetingID: liveMeetingID)
            } else {
                liveMeter = nil
            }
            self?.activeCopilotMeetingID = nil
            let endedMeetingID = await stopping.stop()
            guard let self else { return }
            // Chained behind any earlier generation still in flight (two
            // meetings ended in quick succession) so `settle()` awaiting the
            // latest task transitively awaits them all — the same discipline
            // stopTask uses (critic soft spot: an overwritten task kept
            // running but became untracked).
            let previousGeneration = self.artifactGenerationTask
            self.artifactGenerationTask = Task { [weak self] in
                await previousGeneration?.value
                guard let self else { return }

                // Detached ledger settlement is post-capture bookkeeping. It
                // gates artifact reuse/removal of this meter, but never source
                // shutdown or admission of the next meeting.
                if let liveMeter {
                    do {
                        try await liveMeter.waitForSettlements()
                    } catch is CancellationError {
                        return
                    } catch {
                        self.log.error("meeting spend drain failed: \(String(describing: type(of: error)), privacy: .public)")
                        return
                    }
                }

                if let endedMeetingID {
                    await self.postMeetingAgent()?.generateArtifacts(meetingID: endedMeetingID)
                    await self.removeMeterIfSafe(
                        meetingID: endedMeetingID,
                        meter: liveMeter,
                        ephemeral: false
                    )
                } else if let liveMeetingID {
                    // Ephemeral meetings have no manual artifact retry path and
                    // no persistent state to protect after their settlement.
                    await self.removeMeterIfSafe(
                        meetingID: liveMeetingID,
                        meter: liveMeter,
                        ephemeral: true
                    )
                }
            }
        }
    }

    private func handleFailure(from failed: MeetingPipeline, _ error: any Error) {
        guard pipeline === failed else { return }  // ignore a stale/late failure
        log.error("pipeline failed, stopping session: \(error.localizedDescription)")
        session.stop()
        syncPanel()  // → teardown branch (no await of the calling task, so no self-deadlock)
    }

    /// Test support: await the current start/stop/pause work to quiesce.
    /// Artifact generation is awaited after stop, because stop is what
    /// spawns it.
    func settle() async {
        await startTask?.value
        await stopTask?.value
        await artifactGenerationTask?.value
        await pauseResumeTask?.value
    }

    private func removeMeterIfSafe(
        meetingID: UUID,
        meter: SpendMeter?,
        ephemeral: Bool
    ) async {
        if !ephemeral, let meter, await meter.uncertainUSD(meetingID: meetingID) > 0 {
            // Preserve conservative in-memory debit so a later manual artifact
            // retry cannot fail open after an incomplete provider/ledger result.
            return
        }
        await meetingSpendRegistry.remove(meetingID: meetingID)
    }

    private func applyLiveAISettings(_ settings: LiveAISettings) async {
        copilot.applyLiveSettings(settings)
        if !settings.aiFeaturesEnabled {
            artifactGenerationTask?.cancel()
        } else if activeCopilotMeetingID != nil {
            let providerSettings = (try? await settingsStore()?.providerSettings()) ?? ProviderSettings()
            await refreshActiveCopilotProvider(using: providerSettings)
        }
        await cachedPostMeetingAgent?.setGenerationEnabled(settings.aiFeaturesEnabled)
    }

    private func configureCopilot(
        meetingID: UUID,
        ephemeral: Bool,
        providerSettings: ProviderSettings,
        liveSettings: LiveAISettings,
        pricing: PricingTable
    ) async {
        activeCopilotMeetingID = meetingID
        let registry = ProviderRegistry(profiles: providerProfiles, credentials: credentials)
        let ledger: any SpendLedger
        if let liveSpendLedgerOverride {
            ledger = liveSpendLedgerOverride
        } else if ephemeral {
            ledger = EphemeralSpendLedger()
        } else if let persistent = spendLedger() {
            ledger = persistent
        } else {
            // Capture still wins if the spend database becomes unavailable;
            // the transient meter preserves the cap without claiming disk data.
            ledger = EphemeralSpendLedger()
        }
        let meter = SpendMeter(
            ledger: ledger,
            pricing: pricing,
            capUSD: providerSettings.perMeetingCapUSD
        )
        await meetingSpendRegistry.register(meter, meetingID: meetingID)
        let profile = providerSettings.selectedProfileID.flatMap(registry.profile(id:))
        let client = (try? registry.client(for: providerSettings)) ?? nil
        let metered: (any LLMProvider)? = client.map {
            MeteredProvider(
                upstream: liveProviderOverride ?? $0,
                meter: meter,
                meetingID: meetingID
            )
        }
        copilot.beginMeeting(
            provider: metered,
            // Deliberately use the profile defaults, not persisted overrides.
            fastModel: profile?.fastModel ?? EndpointProfile.deepSeek.fastModel,
            deepModel: profile?.deepModel ?? EndpointProfile.deepSeek.deepModel,
            settings: liveSettings
        )
    }

    /// Re-resolves the selected profile and credential at the moment settings
    /// change. The existing meter is intentionally reused: only transport and
    /// fixed model defaults change; meeting context and accounting lifetime do
    /// not.
    private func refreshActiveCopilotProvider(using settings: ProviderSettings) async {
        guard let meetingID = activeCopilotMeetingID,
              let meter = await meetingSpendRegistry.meter(meetingID: meetingID)
        else { return }

        let registry = ProviderRegistry(profiles: providerProfiles, credentials: credentials)
        let profile = settings.selectedProfileID.flatMap(registry.profile(id:))
        let client = (try? registry.client(for: settings)) ?? nil
        let metered: (any LLMProvider)? = client.map {
            MeteredProvider(
                upstream: liveProviderOverride ?? $0,
                meter: meter,
                meetingID: meetingID
            )
        }
        await copilot.replaceProviderAndWait(
            metered,
            fastModel: profile?.fastModel ?? EndpointProfile.deepSeek.fastModel,
            deepModel: profile?.deepModel ?? EndpointProfile.deepSeek.deepModel
        )
    }
}
