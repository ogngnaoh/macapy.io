import CaptureKit
import Foundation
import TranscribeKit
import os

/// App-lifetime owner of the shell's moving parts. All session mutations flow
/// through `syncPanel()` so panel visibility, the transcript pipeline, and
/// session state stay in lockstep.
@MainActor
final class AppShellCoordinator {
    let session = SessionController()
    /// App-lifetime, stable identity (the panel's hosting view is cached, so the
    /// observed object must not be swapped out).
    let store = TranscriptStore()
    let activationPolicy = ActivationPolicyController()

    private let panel: PanelPresenting
    private let makePipeline: @MainActor (TranscriptStore) -> MeetingPipeline
    private var hotKey: HotKey?
    private var pipeline: MeetingPipeline?
    private var startTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private let log = Logger(subsystem: "io.macapy.app", category: "AppShell")

    /// Production wiring: real mic capture + SpeechAnalyzer. Injected apart so
    /// tests can drive the shell with fakes, no panel, and no global hotkey.
    init(
        panel: PanelPresenting = FloatingPanelController(),
        installHotKey: Bool = true,
        makePipeline: @escaping @MainActor (TranscriptStore) -> MeetingPipeline = AppShellCoordinator.productionPipeline
    ) {
        self.panel = panel
        self.makePipeline = makePipeline
        if installHotKey {
            hotKey = HotKey.startStopMeeting { [weak self] in
                self?.toggleSession()
            }
        }
    }

    static func productionPipeline(_ store: TranscriptStore) -> MeetingPipeline {
        MeetingPipeline(engine: SpeechAnalyzerEngine(), sources: [MicCapture()], store: store)
    }

    func toggleSession() {
        session.toggle()
        syncPanel()
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
        startTask = Task { [weak self] in
            // Serialize behind any in-flight teardown so a prior meeting's tail
            // can't leak into the fresh store after reset().
            await previousStop?.value
            guard let self, self.pipeline === newPipeline else { return }
            self.store.reset()
            do {
                try await newPipeline.start()
            } catch {
                self.handleFailure(from: newPipeline, error)
            }
        }
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

    /// Test support: await the current start/stop work to quiesce.
    func settle() async {
        await startTask?.value
        await stopTask?.value
    }
}
