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
    enum LifecycleCheckpoint: Sendable, Equatable {
        case startupBeforeCommit(UUID)
        case providerRefreshBeforeReplacement(UUID)
    }

    private enum CaptureActivity: Sendable, Equatable {
        case capturing
        case paused

        @MainActor
        func matches(_ session: SessionController) -> Bool {
            switch self {
            case .capturing: session.isCapturing
            case .paused: session.isPaused
            }
        }
    }
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
    @ObservationIgnored private let lifecycleCheckpoint:
        (@Sendable (LifecycleCheckpoint) async -> Void)?
    /// Focused kill-switch test seam. Production persists through
    /// `SettingsStore`; lifecycle tests can hold or fail the write while the
    /// in-memory latch must already be authoritative.
    @ObservationIgnored private let liveSettingsSaveOverride:
        (@Sendable (LiveAISettings) async throws -> Void)?
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
    /// References to the current or most recently started meeting's lock-only
    /// diagnostics. They remain readable after `pipeline` is released, then
    /// switch together when the next pipeline is created.
    @ObservationIgnored private var latestLatencyRecorder: LatencyRecorder?
    @ObservationIgnored private var latestSTTErrorCounter: STTErrorCounter?
    @ObservationIgnored private var latestDroppedChunks: Int?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var stopTask: Task<Void, Never>?
    @ObservationIgnored private var pauseResumeTask: Task<Void, Never>?
    /// Pause/resume transitions form one transitive tail. The revision is the
    /// synchronously updated desired-state authority; the applied state tracks
    /// what the current pipeline's capture sources have actually completed.
    /// Keeping both prevents a skipped stale pause from being followed by an
    /// unnecessary resume, while a pause that was already in flight is always
    /// compensated by the serialized successor.
    @ObservationIgnored private var pauseResumeRevision: UInt64 = 0
    @ObservationIgnored private var pauseResumePipeline: MeetingPipeline?
    @ObservationIgnored private var appliedCaptureActivity: CaptureActivity?
    /// Every post-capture tail remains tracked until it finishes. A single
    /// "latest" task is insufficient: cancelling an overwritten successor
    /// does not cancel the predecessor it is awaiting.
    @ObservationIgnored private var artifactGenerationTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var artifactGenerationTailID: UUID?
    /// Advanced synchronously on every AI-off transition. Automatic tails
    /// capture this token at admission, so an old tail cannot resurrect after
    /// off -> on even if its spend settlement completes later.
    @ObservationIgnored private var automaticArtifactGenerationRevision: UInt64 = 0
    @ObservationIgnored private var copilotTurnsTask: Task<Void, Never>?
    @ObservationIgnored private var activeCopilotMeetingID: UUID?
    @ObservationIgnored private var activeCopilotLifecycleEpoch: UInt64?
    @ObservationIgnored private var lifecycleEpoch: UInt64 = 0
    @ObservationIgnored private var providerTransportRevision: UInt64 = 0
    @ObservationIgnored private var providerRefreshAttemptRevision: UInt64 = 0
    @ObservationIgnored private var providerSettingsRevision: UInt64 = 0
    @ObservationIgnored private var liveSettingsRevision: UInt64 = 0
    @ObservationIgnored private var latestProviderSettings: ProviderSettings?
    @ObservationIgnored private var latestLiveAISettings: LiveAISettings?
    /// App-lifetime kill-switch truth. It changes before settings persistence
    /// can suspend and seeds lazily-created post-meeting agents.
    @ObservationIgnored private var globalAIFeaturesEnabled = true
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
        liveSpendLedgerOverride: (any SpendLedger)? = nil,
        lifecycleCheckpoint: (@Sendable (LifecycleCheckpoint) async -> Void)? = nil,
        liveSettingsSaveOverride:
            (@Sendable (LiveAISettings) async throws -> Void)? = nil
    ) {
        self.panel = panel
        self.makePipeline = makePipeline
        self.makeDatabase = makeDatabase
        self.providerProfiles = providerProfiles
        self.credentials = credentials
        self.postMeetingContextOverride = postMeetingContextOverride
        self.liveProviderOverride = liveProviderOverride
        self.liveSpendLedgerOverride = liveSpendLedgerOverride
        self.lifecycleCheckpoint = lifecycleCheckpoint
        self.liveSettingsSaveOverride = liveSettingsSaveOverride
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
            enqueueCaptureActivity(.paused)
        case .paused:
            session.resume()
            enqueueCaptureActivity(.capturing)
        case .idle:
            break
        }
    }

    /// Serializes capture-layer pause/resume operations and fences every
    /// admission against the latest synchronous SessionController state.
    /// `previous` is deliberately awaited even when it has become stale: an
    /// AudioCaptureSource operation may already be suspended inside system
    /// capture and cannot be assumed cancellation-cooperative. The successor
    /// therefore observes the actual completed state and restores the newest
    /// desired state in order.
    private func enqueueCaptureActivity(_ target: CaptureActivity) {
        guard let transitioning = pipeline else { return }
        pauseResumeRevision &+= 1
        let revision = pauseResumeRevision
        let previous = pauseResumeTask
        let startup = startTask
        pauseResumeTask = Task { @MainActor [weak self] in
            await previous?.value
            // A pause can be requested immediately after the synchronous
            // session start. Do not call a source before pipeline.start() has
            // installed it; teardown cancels this startup and awaits this tail.
            await startup?.value
            guard let self,
                  self.isCurrentCaptureActivity(
                    target,
                    revision: revision,
                    pipeline: transitioning
                  )
            else { return }

            switch target {
            case .paused:
                // Suppress automatic work before halting capture. A newer
                // desired state still chains behind this whole transition.
                await self.copilot.setAutomaticSuppressed(true)
                guard self.isCurrentCaptureActivity(
                    target,
                    revision: revision,
                    pipeline: transitioning
                ) else { return }
                if self.appliedCaptureActivity != .paused {
                    await transitioning.pause()
                    self.recordAppliedCaptureActivity(.paused, pipeline: transitioning)
                }

            case .capturing:
                if self.appliedCaptureActivity != .capturing {
                    await transitioning.resume()
                    self.recordAppliedCaptureActivity(.capturing, pipeline: transitioning)
                }
                guard self.isCurrentCaptureActivity(
                    target,
                    revision: revision,
                    pipeline: transitioning
                ) else { return }
                // Resume capture first, then permit automatic work. If this
                // transition became stale while the source was suspended, the
                // guard leaves suppression intact for the queued pause.
                await self.copilot.setAutomaticSuppressed(false)
            }
        }
    }

    private func isCurrentCaptureActivity(
        _ target: CaptureActivity,
        revision: UInt64,
        pipeline expectedPipeline: MeetingPipeline
    ) -> Bool {
        pauseResumeRevision == revision
            && pipeline === expectedPipeline
            && pauseResumePipeline === expectedPipeline
            && target.matches(session)
    }

    /// Physical capture completion is recorded even when the request became
    /// stale during its source await. The next serialized transition needs
    /// that fact to decide whether compensation is required. Never let an old
    /// pipeline write through a newer meeting's ownership boundary.
    private func recordAppliedCaptureActivity(
        _ activity: CaptureActivity,
        pipeline completedPipeline: MeetingPipeline
    ) {
        guard pauseResumePipeline === completedPipeline else { return }
        appliedCaptureActivity = activity
    }

    func requestCatchUp() { copilot.requestCatchUp() }
    func requestAsk() {
        guard copilot.canAsk else { return }
        copilot.requestAsk()
        panel.focusQuery()
    }
    func requestDismissCopilot() {
        copilot.dismissCard()
    }

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
        lifecycleEpoch &+= 1
        let startupEpoch = lifecycleEpoch
        let previousStop = stopTask
        let newPipeline = makePipeline(store)
        pipeline = newPipeline
        pauseResumePipeline = newPipeline
        appliedCaptureActivity = .capturing
        latestLatencyRecorder = newPipeline.recorder
        latestSTTErrorCounter = newPipeline.sttErrorCounter
        latestDroppedChunks = 0
        copilot.suggestionLatencyRecorder.reset()
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
                    await self.copilot.receive(
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
                // A settings callback can win while either database read is
                // suspended. Never overwrite that newer in-memory truth with
                // the stale read that just returned.
                if self.latestProviderSettings == nil {
                    self.latestProviderSettings = providerSettings
                }
                if self.latestLiveAISettings == nil {
                    self.latestLiveAISettings = liveSettings
                    self.globalAIFeaturesEnabled = liveSettings.aiFeaturesEnabled
                    if !liveSettings.aiFeaturesEnabled {
                        await self.cachedPostMeetingAgent?.setGenerationEnabled(false)
                    }
                }
                guard self.isCurrentStartup(newPipeline, epoch: startupEpoch) else { return }
                try await newPipeline.start(mode: mode) { [weak self] meetingID, isEphemeral in
                    guard let self,
                          self.isCurrentStartup(newPipeline, epoch: startupEpoch)
                    else { return }
                    await self.configureCopilot(
                        meetingID: meetingID,
                        ephemeral: isEphemeral,
                        providerSettings: providerSettings,
                        liveSettings: liveSettings,
                        pricing: pricing,
                        expectedPipeline: newPipeline,
                        lifecycleEpoch: startupEpoch
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
        latestLatencyRecorder
    }

    /// Signal-strip data source (slice-4 decision 5); nil when no pipeline has
    /// existed yet — the strip falls back to session-state rendering.
    var currentSignalMeter: SignalLevelMeter? {
        pipeline?.signalMeter
    }

    /// Diagnostics "Dropped chunks" tile (slice-4 decision 4).
    var currentDroppedChunks: Int? {
        pipeline?.droppedChunks ?? latestDroppedChunks
    }

    struct DiagnosticsSnapshot: Sendable, Equatable {
        let hasMeeting: Bool
        let speech: LatencyReport?
        let suggestion: SuggestionLatencyRecorder.Report
        let memoryBytes: UInt64?
        let artifactG3Seconds: Double?
        let droppedChunks: Int
        let sttErrorCount: Int
    }

    /// One coherent polling read for the diagnostics grid. The recorder and
    /// counters are lock-protected snapshots; the actor-owned G3 value is read
    /// only from an agent already constructed by normal app flow, so opening
    /// Diagnostics never opens storage or configures a provider.
    func diagnosticsSnapshot() async -> DiagnosticsSnapshot {
        let recorder = latestLatencyRecorder
        let sttCounter = latestSTTErrorCounter
        let dropped = pipeline?.droppedChunks ?? latestDroppedChunks ?? 0
        // Snapshot every per-meeting lock source before the actor hop to G3;
        // a new meeting can begin while that await is suspended.
        let speech = recorder?.report()
        let suggestion = copilot.suggestionLatencyRecorder.report()
        let memoryBytes = MemoryFootprint.currentBytes()
        let g3: Double? = if let agent = cachedPostMeetingAgent {
            await agent.lastDraftedInSeconds
        } else {
            nil
        }
        return DiagnosticsSnapshot(
            hasMeeting: recorder != nil,
            speech: speech,
            suggestion: suggestion,
            memoryBytes: memoryBytes,
            artifactG3Seconds: g3,
            droppedChunks: dropped,
            sttErrorCount: sttCounter?.count ?? 0
        )
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
            onSettingsChange: { [weak self] settings, change in
                guard let self else { return }
                self.latestProviderSettings = settings
                self.providerSettingsRevision &+= 1
                switch change {
                case .cap:
                    await self.applyCapChange(settings.perMeetingCapUSD)
                case .modelOverride:
                    // Fixed DeepSeek model ids ignore these preserved values.
                    // In particular, do not clear a completed requested card.
                    break
                case .transport:
                    self.providerTransportRevision &+= 1
                    let revision = self.providerTransportRevision
                    await self.applyCapChange(settings.perMeetingCapUSD)
                    _ = await self.refreshActiveCopilotProvider(
                        using: settings,
                        expectedTransportRevision: revision
                    )
                }
            }
        )
        cachedProviderSettingsModel = model
        return model
    }

    func liveAISettingsModel() -> LiveAISettingsModel {
        if let cachedLiveAISettingsModel { return cachedLiveAISettingsModel }
        let onChange: @MainActor (LiveAISettings) async -> Void = { [weak self] settings in
            await self?.applyLiveAISettings(settings)
        }
        let model: LiveAISettingsModel
        if let liveSettingsSaveOverride {
            model = LiveAISettingsModel(
                testingSaveSettings: liveSettingsSaveOverride,
                onChange: onChange
            )
        } else {
            model = LiveAISettingsModel(store: settingsStore(), onChange: onChange)
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
        let ledgerOverride = liveSpendLedgerOverride
        let agent = PostMeetingAgent(
            meetings: meetings,
            artifacts: artifacts,
            generationEnabled: globalAIFeaturesEnabled,
            onGenerationFinished: { [weak self] meetingID, outcome in
                await self?.cleanupMeterAfterGeneration(
                    meetingID: meetingID,
                    outcome: outcome,
                    expectedMeter: nil
                )
            },
            makeContext: { meetingID in
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
                    let candidate = SpendMeter(
                        ledger: ledgerOverride ?? ledger,
                        pricing: try await settingsStore.pricing(),
                        capUSD: settings.perMeetingCapUSD
                    )
                    // Manual generations can race (or retry after an uncertain
                    // settlement). Atomically retain exactly one meeting meter so
                    // every attempt sees the same conservative debit.
                    meter = await meterRegistry.registerIfAbsent(candidate, meetingID: meetingID)
                }
                return PostMeetingProviderContext(
                    provider: MeteredProvider(upstream: client, meter: meter, meetingID: meetingID),
                    // Production ignores preserved model overrides for the MVP.
                    model: profile.deepModel
                )
            }
        )
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
        latestDroppedChunks = stopping.droppedChunks
        pipeline = nil
        // Idle is authoritative immediately. Invalidate pending admissions and
        // detach the applied-state owner so an old source completion cannot
        // write into a subsequently created meeting's state.
        pauseResumeRevision &+= 1
        let inFlightPauseResume = pauseResumeTask
        if pauseResumePipeline === stopping {
            pauseResumePipeline = nil
            appliedCaptureActivity = nil
        }
        lifecycleEpoch &+= 1
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
            // Capture is the critical path: synchronously cancel presentation
            // work, but never await it here. A completed classifier can still
            // be draining a detached ledger settlement; the artifact task
            // below owns that wait so source shutdown and the next meeting do
            // not inherit it.
            self?.copilot.stopMeeting()
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
            self?.activeCopilotLifecycleEpoch = nil
            // A source pause/resume may ignore task cancellation while inside
            // platform capture. Live AI is already stopped above; now drain
            // the source transition before stop(), and therefore before a
            // later meeting (whose start awaits this stop tail) can touch
            // capture. The revision fence prevents stale presentation changes
            // after SessionController moved to idle.
            await inFlightPauseResume?.value
            let endedMeetingID = await stopping.stop()
            guard let self else { return }
            // A newer pipeline may already own the retained diagnostics by the
            // time this old drain completes. Never let its zero/current value
            // be overwritten by stale teardown.
            if self.latestLatencyRecorder === stopping.recorder {
                self.latestDroppedChunks = stopping.droppedChunks
            }
            // This unstructured owner is intentionally independent of the
            // artifact task's cancellation. Global AI-off may cancel artifact
            // generation, but a live reservation still needs to settle and an
            // ephemeral meter still needs deterministic removal.
            let settlementOwner = liveMeter.map { meter in
                Task { try await meter.waitForSettlements() }
            }
            self.enqueueArtifactGeneration(
                endedMeetingID: endedMeetingID,
                liveMeetingID: liveMeetingID,
                liveMeter: liveMeter,
                settlementOwner: settlementOwner
            )
        }
    }

    /// Serializes automatic generation tails while retaining every task as a
    /// first-class cancellation owner. Admission is snapshotted when the task
    /// is created, not when an earlier settlement finally releases it.
    private func enqueueArtifactGeneration(
        endedMeetingID: UUID?,
        liveMeetingID: UUID?,
        liveMeter: SpendMeter?,
        settlementOwner: Task<Void, Error>?
    ) {
        let taskID = UUID()
        let previousGeneration = artifactGenerationTailID.flatMap {
            artifactGenerationTasks[$0]
        }
        let enabledAtAdmission = globalAIFeaturesEnabled
        let admissionRevision = automaticArtifactGenerationRevision
        let task = Task { [weak self] in
            await previousGeneration?.value
            guard let self else { return }
            await self.runArtifactGeneration(
                endedMeetingID: endedMeetingID,
                liveMeetingID: liveMeetingID,
                liveMeter: liveMeter,
                settlementOwner: settlementOwner,
                enabledAtAdmission: enabledAtAdmission,
                admissionRevision: admissionRevision
            )
            self.finishArtifactGenerationTask(taskID)
        }
        artifactGenerationTasks[taskID] = task
        artifactGenerationTailID = taskID
    }

    private func runArtifactGeneration(
        endedMeetingID: UUID?,
        liveMeetingID: UUID?,
        liveMeter: SpendMeter?,
        settlementOwner: Task<Void, Error>?,
        enabledAtAdmission: Bool,
        admissionRevision: UInt64
    ) async {
        // Detached ledger settlement is post-capture bookkeeping. It gates
        // artifact reuse/removal of this meter, but never source shutdown or
        // admission of the next meeting. It must drain even after this
        // automatic task is cancelled.
        if let settlementOwner {
            do {
                try await settlementOwner.value
            } catch {
                log.error("meeting spend drain failed: \(String(describing: type(of: error)), privacy: .public)")
                if endedMeetingID == nil, let liveMeetingID, let liveMeter {
                    await meetingSpendRegistry.remove(
                        meetingID: liveMeetingID, ifSameAs: liveMeter)
                }
                return
            }
        }

        if let endedMeetingID {
            // Every condition is required immediately before crossing the
            // PostMeetingAgent admission boundary. In particular, enablement
            // after a kill-switch transition cannot revive an older task.
            guard !Task.isCancelled,
                  enabledAtAdmission,
                  globalAIFeaturesEnabled,
                  automaticArtifactGenerationRevision == admissionRevision
            else {
                await removeMeterIfSafe(
                    meetingID: endedMeetingID,
                    meter: liveMeter,
                    ephemeral: false
                )
                return
            }
            guard let agent = postMeetingAgent() else {
                await removeMeterIfSafe(
                    meetingID: endedMeetingID,
                    meter: liveMeter,
                    ephemeral: false
                )
                return
            }
            // Outcome-aware cleanup is owned by PostMeetingAgent and finishes
            // before it releases this meeting's reentrancy guard.
            _ = await agent.generateArtifacts(meetingID: endedMeetingID)
        } else if let liveMeetingID {
            // Ephemeral meetings have no artifact path or manual retry. Their
            // meter cleanup intentionally outlives cancellation/AI-off.
            await removeMeterIfSafe(
                meetingID: liveMeetingID,
                meter: liveMeter,
                ephemeral: true
            )
        }
    }

    private func finishArtifactGenerationTask(_ taskID: UUID) {
        artifactGenerationTasks[taskID] = nil
        if artifactGenerationTailID == taskID {
            artifactGenerationTailID = nil
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
        while let task = artifactGenerationTasks.values.first {
            await task.value
        }
        // The tail is transitive, and the revision loop also catches a newer
        // transition enqueued while an earlier await yielded.
        while true {
            let revision = pauseResumeRevision
            await pauseResumeTask?.value
            if revision == pauseResumeRevision { break }
        }
    }

    /// Focused lifecycle-test seam: waits until capture teardown has handed
    /// post-capture bookkeeping to its independently owned task, without also
    /// waiting for a deliberately blocked spend settlement.
    func settleCaptureLifecycle() async {
        await startTask?.value
        await stopTask?.value
    }

    private func removeMeterIfSafe(
        meetingID: UUID,
        meter: SpendMeter?,
        ephemeral: Bool,
        preserveUncertain: Bool = true
    ) async {
        let retainedMeter: SpendMeter?
        if let meter {
            retainedMeter = meter
        } else {
            retainedMeter = await meetingSpendRegistry.meter(meetingID: meetingID)
        }
        if preserveUncertain, !ephemeral, let retainedMeter,
           await retainedMeter.uncertainUSD(meetingID: meetingID) > 0
        {
            // Preserve conservative in-memory debit so a later manual artifact
            // retry cannot fail open after an incomplete provider/ledger result.
            return
        }
        if let retainedMeter {
            await meetingSpendRegistry.remove(meetingID: meetingID, ifSameAs: retainedMeter)
        } else {
            await meetingSpendRegistry.remove(meetingID: meetingID)
        }
    }

    func cleanupMeterAfterGeneration(
        meetingID: UUID,
        outcome: PostMeetingAgent.Outcome,
        expectedMeter: SpendMeter?
    ) async {
        // This outcome belongs to another caller which still owns the meter.
        // Removing it here would let that caller's in-flight request escape
        // both its reservation and any conservative uncertain debit.
        guard outcome != .skippedGenerationInFlight else { return }
        let preserveUncertain: Bool
        switch outcome {
        case .failed, .halted, .cancelled, .skippedNoProvider:
            preserveUncertain = true
        case .drafted, .skippedExistingArtifacts, .skippedEmptyTranscript, .skippedEphemeral:
            preserveUncertain = false
        case .skippedGenerationInFlight:
            return
        }
        await removeMeterIfSafe(
            meetingID: meetingID,
            meter: expectedMeter,
            ephemeral: false,
            preserveUncertain: preserveUncertain
        )
    }

    private func applyLiveAISettings(_ settings: LiveAISettings) async {
        liveSettingsRevision &+= 1
        let revision = liveSettingsRevision
        latestLiveAISettings = settings
        // This assignment is deliberately before the first suspension. The
        // kill switch is operational state; persistence is only its durable
        // copy and cannot be allowed to delay or roll back it.
        globalAIFeaturesEnabled = settings.aiFeaturesEnabled
        if !settings.aiFeaturesEnabled {
            automaticArtifactGenerationRevision &+= 1
            // Disable synchronously before any suspension. This wins against a
            // stale startup or enable callback that later resumes.
            await copilot.applyLiveSettings(settings)
            for task in artifactGenerationTasks.values {
                task.cancel()
            }
            await cachedPostMeetingAgent?.setGenerationEnabled(false)
            return
        }

        while activeCopilotMeetingID != nil, copilot.availability == .disabled {
            // The retained provider may have stale credentials. Refresh while
            // admission is still disabled, and expose it only after both the
            // transport drain and the current live/transport revisions commit.
            // A transport callback can interleave while this callback awaits
            // settings. In that case retry with the newest snapshot rather
            // than exposing the retained provider.
            let providerSettings: ProviderSettings
            if let latestProviderSettings {
                providerSettings = latestProviderSettings
            } else {
                providerSettings = (try? await settingsStore()?.providerSettings())
                    ?? ProviderSettings()
            }
            guard liveSettingsRevision == revision,
                  latestLiveAISettings?.aiFeaturesEnabled == true
            else { return }
            latestProviderSettings = providerSettings
            let transportRevision = providerTransportRevision
            let committed = await refreshActiveCopilotProvider(
                using: providerSettings,
                expectedTransportRevision: transportRevision
            )
            guard liveSettingsRevision == revision,
                  latestLiveAISettings?.aiFeaturesEnabled == true
            else { return }
            guard providerTransportRevision == transportRevision, committed else {
                continue
            }
            break
        }
        await copilot.applyLiveSettings(settings)
        await cachedPostMeetingAgent?.setGenerationEnabled(true)
    }

    private func configureCopilot(
        meetingID: UUID,
        ephemeral: Bool,
        providerSettings: ProviderSettings,
        liveSettings: LiveAISettings,
        pricing: PricingTable,
        expectedPipeline: MeetingPipeline,
        lifecycleEpoch expectedEpoch: UInt64
    ) async {
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
        guard isCurrentStartup(expectedPipeline, epoch: expectedEpoch) else { return }
        let registeredMeter = await meetingSpendRegistry.registerIfAbsent(meter, meetingID: meetingID)

        await lifecycleCheckpoint?(.startupBeforeCommit(meetingID))
        guard isCurrentStartup(expectedPipeline, epoch: expectedEpoch) else {
            await meetingSpendRegistry.remove(meetingID: meetingID, ifSameAs: registeredMeter)
            return
        }

        // Resolve stable final snapshots only after every startup suspension.
        // A settings callback can interleave with the meter actor hop, so retry
        // until both revisions are unchanged across it.
        var finalProviderSettings = providerSettings
        var finalLiveSettings = liveSettings
        while true {
            let providerRevision = providerSettingsRevision
            let liveRevision = liveSettingsRevision
            finalProviderSettings = latestProviderSettings ?? providerSettings
            finalLiveSettings = latestLiveAISettings ?? liveSettings
            await registeredMeter.updateCapUSD(finalProviderSettings.perMeetingCapUSD)
            guard isCurrentStartup(expectedPipeline, epoch: expectedEpoch) else {
                await meetingSpendRegistry.remove(meetingID: meetingID, ifSameAs: registeredMeter)
                return
            }
            if providerRevision == providerSettingsRevision,
               liveRevision == liveSettingsRevision
            {
                break
            }
        }
        let registry = ProviderRegistry(profiles: providerProfiles, credentials: credentials)
        let profile = finalProviderSettings.selectedProfileID.flatMap(registry.profile(id:))
        let client = (try? registry.client(for: finalProviderSettings)) ?? nil
        let metered: (any LLMProvider)? = client.map {
            MeteredProvider(
                upstream: liveProviderOverride ?? $0,
                meter: registeredMeter,
                meetingID: meetingID
            )
        }
        // No await between this final identity check and committing all three
        // meeting owners, so teardown/settings cannot interleave halfway.
        guard isCurrentStartup(expectedPipeline, epoch: expectedEpoch) else {
            await meetingSpendRegistry.remove(meetingID: meetingID, ifSameAs: registeredMeter)
            return
        }
        activeCopilotMeetingID = meetingID
        activeCopilotLifecycleEpoch = expectedEpoch
        copilot.beginMeeting(
            meetingID: meetingID,
            provider: metered,
            // Deliberately use the profile defaults, not persisted overrides.
            fastModel: profile?.fastModel ?? EndpointProfile.deepSeek.fastModel,
            deepModel: profile?.deepModel ?? EndpointProfile.deepSeek.deepModel,
            settings: finalLiveSettings
        )
    }

    /// Re-resolves the selected profile and credential at the moment settings
    /// change. The existing meter is intentionally reused: only transport and
    /// fixed model defaults change; meeting context and accounting lifetime do
    /// not.
    private func refreshActiveCopilotProvider(
        using settings: ProviderSettings,
        expectedTransportRevision: UInt64
    ) async -> Bool {
        providerRefreshAttemptRevision &+= 1
        let attemptRevision = providerRefreshAttemptRevision
        guard let meetingID = activeCopilotMeetingID,
              let expectedEpoch = activeCopilotLifecycleEpoch,
              let meter = await meetingSpendRegistry.meter(meetingID: meetingID)
        else { return false }

        guard activeCopilotMeetingID == meetingID,
              activeCopilotLifecycleEpoch == expectedEpoch,
              lifecycleEpoch == expectedEpoch,
              providerTransportRevision == expectedTransportRevision,
              providerRefreshAttemptRevision == attemptRevision
        else { return false }

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
        await lifecycleCheckpoint?(.providerRefreshBeforeReplacement(meetingID))
        guard activeCopilotMeetingID == meetingID,
              activeCopilotLifecycleEpoch == expectedEpoch,
              lifecycleEpoch == expectedEpoch,
              providerTransportRevision == expectedTransportRevision,
              providerRefreshAttemptRevision == attemptRevision
        else { return false }
        await copilot.replaceProviderAndWait(
            metered,
            fastModel: profile?.fastModel ?? EndpointProfile.deepSeek.fastModel,
            deepModel: profile?.deepModel ?? EndpointProfile.deepSeek.deepModel,
            expectedMeetingID: meetingID,
            replacementID: UUID()
        )
        return activeCopilotMeetingID == meetingID
            && activeCopilotLifecycleEpoch == expectedEpoch
            && lifecycleEpoch == expectedEpoch
            && providerTransportRevision == expectedTransportRevision
            && providerRefreshAttemptRevision == attemptRevision
    }

    private func applyCapChange(_ capUSD: Double?) async {
        let capRaised = await meetingSpendRegistry.updateCaps(
            capUSD,
            activeMeetingID: activeCopilotMeetingID
        )
        if capRaised { copilot.releaseCapPauseAfterCapIncrease() }
    }

    private func isCurrentStartup(_ expectedPipeline: MeetingPipeline, epoch: UInt64) -> Bool {
        pipeline === expectedPipeline && lifecycleEpoch == epoch && session.isCapturing
    }

    /// Focused lifecycle oracle: production has no reason to enumerate these.
    func retainedSpendMeterCount() async -> Int {
        await meetingSpendRegistry.count()
    }

    func retainedUncertainSpend(meetingID: UUID) async -> Double? {
        await meetingSpendRegistry.uncertainUSD(meetingID: meetingID)
    }

    /// Focused ownership-test seam: production registers through live startup
    /// or the post-meeting context factory.
    func retainSpendMeterForTesting(_ meter: SpendMeter, meetingID: UUID) async {
        await meetingSpendRegistry.register(meter, meetingID: meetingID)
    }
}
