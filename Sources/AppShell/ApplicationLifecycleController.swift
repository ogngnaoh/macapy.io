import AppKit
import Foundation
import Observation

/// The termination deadline bounds the UI response, not the lifetime of a
/// capture operation that ignores cancellation. A timeout cancels quitting and
/// keeps the single drain owner alive; it never forces transcript loss.
@MainActor
@Observable
final class ApplicationLifecycleController {
    enum Phase: Equatable { case idle, draining, waitingForDrain }
    private(set) var phase: Phase = .idle
    private let onSleep: @MainActor () -> Void
    private let drainForTermination: @MainActor () async -> Void
    private let onTimeout: @MainActor () -> Void
    private let timeout: Duration
    @ObservationIgnored private var drainTask: Task<Void, Never>?
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?
    @ObservationIgnored private var reply: (@MainActor (Bool) -> Void)?
    @ObservationIgnored private var requestID: UUID?

    init(
        onSleep: @escaping @MainActor () -> Void,
        drainForTermination: @escaping @MainActor () async -> Void,
        onTimeout: @escaping @MainActor () -> Void,
        timeout: Duration = .seconds(5)
    ) {
        self.onSleep = onSleep
        self.drainForTermination = drainForTermination
        self.onTimeout = onTimeout
        self.timeout = timeout
    }

    func receiveSleep() { onSleep() }

    func requestTermination(reply: @escaping @MainActor (Bool) -> Void) {
        // AppKit already has one outstanding terminateLater reply. Repeated
        // menu/key requests cannot create more drain owners or timer races.
        guard self.reply == nil else { return }
        self.reply = reply
        let id = UUID()
        requestID = id
        phase = .draining
        if drainTask == nil {
            drainTask = Task { [self] in
                await drainForTermination()
                drainTask = nil
                timeoutTask?.cancel()
                timeoutTask = nil
                let answer = self.reply
                self.reply = nil
                requestID = nil
                phase = .idle
                answer?(true)
            }
        }
        timeoutTask = Task { [self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard requestID == id, let answer = self.reply else { return }
            self.reply = nil
            requestID = nil
            phase = .waitingForDrain
            answer(false)
            onTimeout()
        }
    }
}

/// The app entry point installs this delegate through SwiftUI's adaptor. The
/// production scene supplies the controller; isolated sample launch leaves it
/// nil and performs no production lifecycle/storage/capture construction.
@MainActor
public final class MacapyApplicationDelegate: NSObject, NSApplicationDelegate {
    static var lifecycle: ApplicationLifecycleController?
    private var sleepObserver: NSObjectProtocol?

    public override init() { super.init() }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in Self.lifecycle?.receiveSleep() }
        }
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let lifecycle = Self.lifecycle else { return .terminateNow }
        lifecycle.requestTermination { allowed in sender.reply(toApplicationShouldTerminate: allowed) }
        return .terminateLater
    }

    public func applicationWillTerminate(_ notification: Notification) {
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        sleepObserver = nil
    }
}
