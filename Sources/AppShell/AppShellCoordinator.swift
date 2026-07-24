import CaptureKit
import Foundation
import Observation
import PersistKit
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

    /// Menu-bar "Ephemeral meeting" toggle: applies to the *next* meeting
    /// started, not one already running (slice-04 doc decision 9).
    var ephemeralNextMeeting = false

    @ObservationIgnored private let panel: PanelPresenting
    @ObservationIgnored private let makePipeline: @MainActor (TranscriptStore) -> MeetingPipeline
    @ObservationIgnored private let makePersistentStore: @MainActor () throws -> MeetingStore
    @ObservationIgnored private var cachedPersistentStore: MeetingStore?
    @ObservationIgnored private var hotKey: HotKey?
    @ObservationIgnored private var pauseHotKey: HotKey?
    @ObservationIgnored private var pipeline: MeetingPipeline?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var stopTask: Task<Void, Never>?
    @ObservationIgnored private var pauseResumeTask: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "io.macapy.app", category: "AppShell")

    /// Production wiring: real mic + system-audio capture, SpeechAnalyzer, and
    /// an on-disk GRDB store under `~/Library/Application Support/macapy/`.
    /// Injected apart so tests can drive the shell with fakes, no panel, no
    /// global hotkeys, and no real disk access.
    ///
    /// `makePersistentStore` has no default on purpose: a defaulted production
    /// store let a test silently write into the real on-disk database (M1
    /// close-out defect). Every caller — the app's composition root included —
    /// must now choose its store explicitly.
    init(
        panel: PanelPresenting = FloatingPanelController(),
        installHotKey: Bool = true,
        makePipeline: @escaping @MainActor (TranscriptStore) -> MeetingPipeline = AppShellCoordinator.productionPipeline,
        makePersistentStore: @escaping @MainActor () throws -> MeetingStore
    ) {
        self.panel = panel
        self.makePipeline = makePipeline
        self.makePersistentStore = makePersistentStore
        if installHotKey {
            hotKey = HotKey.startStopMeeting { [weak self] in
                self?.toggleSession()
            }
            pauseHotKey = HotKey.pauseResumeMeeting { [weak self] in
                self?.togglePause()
            }
        }
    }

    static func productionPipeline(_ store: TranscriptStore) -> MeetingPipeline {
        // Two capture sources: mic (You) + system-audio process tap (Them). Both
        // feed the one engine's per-source transcribe() calls into the shared
        // store, which interleaves by tStart. Fakes are injected in tests via the
        // makePipeline closure, so this production wiring is test-inert.
        MeetingPipeline(
            engine: SpeechAnalyzerEngine(),
            sources: [MicCapture(), SystemAudioCapture()],
            store: store)
    }

    /// The production on-disk database (SPEC §5): `~/Library/Application
    /// Support/macapy/macapy.sqlite`. Creates the containing directory on
    /// first use; test wiring never calls this (see `makePersistentStore`).
    static func productionMeetingStore() throws -> MeetingStore {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let dbURL = appSupport
            .appendingPathComponent("macapy", isDirectory: true)
            .appendingPathComponent("macapy.sqlite")
        return MeetingStore(database: try MacapyDatabase.onDisk(at: dbURL))
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
            let pausing = pipeline
            pauseResumeTask = Task { await pausing?.pause() }
        case .paused:
            session.resume()
            let resuming = pipeline
            pauseResumeTask = Task { await resuming?.resume() }
        case .idle:
            break
        }
    }

    private func syncPanel() {
        if session.isCapturing {
            panel.show(session: session, store: store)
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
            do {
                let mode = try self.resolvePersistenceMode(ephemeral: ephemeral)
                try await newPipeline.start(mode: mode)
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
        let opened = try makePersistentStore()
        cachedPersistentStore = opened
        return opened
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
        stopTask = Task {
            inFlightStart?.cancel()
            await previousStop?.value
            await stopping.stop()
        }
    }

    private func handleFailure(from failed: MeetingPipeline, _ error: any Error) {
        guard pipeline === failed else { return }  // ignore a stale/late failure
        log.error("pipeline failed, stopping session: \(error.localizedDescription)")
        session.stop()
        syncPanel()  // → teardown branch (no await of the calling task, so no self-deadlock)
    }

    /// Test support: await the current start/stop/pause work to quiesce.
    func settle() async {
        await startTask?.value
        await stopTask?.value
        await pauseResumeTask?.value
    }
}
