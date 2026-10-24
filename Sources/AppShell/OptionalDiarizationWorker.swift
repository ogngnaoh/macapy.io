import CaptureKit
import DiarizeKit
import Foundation
import PersistKit
import os

/// One process-wide optional platform operation, including an operation that
/// ignores cancellation. Only its actual exit releases the lease.
final class OptionalDiarizationLease: @unchecked Sendable {
    static let shared = OptionalDiarizationLease()
    private let lock = NSLock()
    private var owner: UUID?

    func acquire() -> UUID? {
        lock.withLock {
            guard owner == nil else { return nil }
            let id = UUID()
            owner = id
            return id
        }
    }

    func release(_ id: UUID) { lock.withLock { if owner == id { owner = nil } } }
    var isOccupied: Bool { lock.withLock { owner != nil } }
}

final class DiarizationFence: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    var isCurrent: Bool { lock.withLock { active } }
    @discardableResult func invalidate() -> Bool {
        lock.withLock { let previous = active; active = false; return previous }
    }
}

/// Independent bounds prevent a high audio rate from evicting final metadata.
/// Overflow cancels attribution: FluidAudio's cumulative clock cannot safely
/// label a discontinuous audio stream without an explicit timing contract.
final class DiarizationInbox: @unchecked Sendable {
    enum Input: Sendable {
        case audio(AudioChunk)
        case final(DiarizationSegmentSnapshot)
    }
    private struct Entry: Sendable { let order: UInt64; let input: Input }
    private let lock = NSLock()
    private let audioLimit: Int
    private let finalLimit: Int
    private var audio: [Entry] = []
    private var finals: [Entry] = []
    private var sequence: UInt64 = 0
    private var finished = false
    private var cancelled = false
    private var waiter: CheckedContinuation<Input?, Never>?
    private var audioDrops = 0

    init(audioLimit: Int = 100, finalLimit: Int = 256) {
        precondition(audioLimit > 0 && finalLimit > 0)
        self.audioLimit = audioLimit
        self.finalLimit = finalLimit
    }

    /// False means overflow, not an ordinary post-close input.
    func append(_ input: Input) -> Bool {
        let outcome = lock.withLock { () -> (Bool, CheckedContinuation<Input?, Never>?) in
            guard !finished && !cancelled else { return (true, nil) }
            if let waiter { self.waiter = nil; return (true, waiter) }
            let entry = Entry(order: sequence, input: input)
            sequence &+= 1
            switch input {
            case .audio:
                guard audio.count < audioLimit else { audioDrops += 1; return (false, nil) }
                audio.append(entry)
            case .final:
                guard finals.count < finalLimit else { return (false, nil) }
                finals.append(entry)
            }
            return (true, nil)
        }
        outcome.1?.resume(returning: input)
        return outcome.0
    }

    func next() async -> Input? {
        await withCheckedContinuation { continuation in
            let immediate = lock.withLock { () -> (Bool, Input?) in
                if cancelled { return (true, nil) }
                if let a = audio.first, finals.first.map({ a.order < $0.order }) ?? true {
                    audio.removeFirst(); return (true, a.input)
                }
                if let f = finals.first { finals.removeFirst(); return (true, f.input) }
                if finished { return (true, nil) }
                precondition(waiter == nil)
                waiter = continuation
                return (false, nil)
            }
            if immediate.0 { continuation.resume(returning: immediate.1) }
        }
    }

    func finish() {
        let waiting = lock.withLock { () -> CheckedContinuation<Input?, Never>? in
            finished = true
            defer { waiter = nil }
            return waiter
        }
        waiting?.resume(returning: nil)
    }

    func cancel() {
        let waiting = lock.withLock { () -> CheckedContinuation<Input?, Never>? in
            cancelled = true
            audio.removeAll(); finals.removeAll()
            defer { waiter = nil }
            return waiter
        }
        waiting?.resume(returning: nil)
    }

    var droppedAudio: Int { lock.withLock { audioDrops } }
    var bufferedCounts: (audio: Int, finals: Int) { lock.withLock { (audio.count, finals.count) } }
}

struct DiarizationWorkerResult: Sendable {
    let diarization: MeetingDiarization
    let segments: [DiarizationSegmentSnapshot]
}

/// A continuation race, deliberately not a task group: a platform worker may
/// ignore cancellation, and a group would wait for that child on scope exit.
private final class DiarizationCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private var result: DiarizationWorkerResult?
    private var waiter: CheckedContinuation<DiarizationWorkerResult?, Never>?

    func finish(_ result: DiarizationWorkerResult?) {
        let waiting = lock.withLock { () -> CheckedContinuation<DiarizationWorkerResult?, Never>? in
            guard !completed else { return nil }
            completed = true
            self.result = result
            defer { waiter = nil }
            return waiter
        }
        waiting?.resume(returning: result)
    }

    func wait(grace: Duration) async -> DiarizationWorkerResult? {
        await withCheckedContinuation { continuation in
            let immediate = lock.withLock { () -> (Bool, DiarizationWorkerResult?) in
                if completed { return (true, result) }
                precondition(waiter == nil)
                waiter = continuation
                return (false, nil)
            }
            if immediate.0 { continuation.resume(returning: immediate.1) }
            else {
                Task.detached { [self] in
                    try? await Task.sleep(for: grace)
                    finish(nil)
                }
            }
        }
    }
}

final class OptionalDiarizationWorker: @unchecked Sendable {
    let fence = DiarizationFence()
    private let inbox: DiarizationInbox
    private let completion = DiarizationCompletion()
    private let task: Task<Void, Never>
    private let onUnavailable: @MainActor @Sendable () -> Void

    init(
        lease: OptionalDiarizationLease, leaseID: UUID,
        inbox: DiarizationInbox = DiarizationInbox(),
        makeSession: @escaping @Sendable () throws -> DiarizationSession,
        onLabels: @escaping @MainActor @Sendable ([LiveAttribution]) -> Void,
        onUnavailable: @escaping @MainActor @Sendable () -> Void
    ) {
        self.inbox = inbox
        self.onUnavailable = onUnavailable
        let fence = self.fence
        let completion = self.completion
        task = Task.detached(priority: .utility) {
            defer { lease.release(leaseID) }
            do {
                try Task.checkCancellation()
                let session = try makeSession()
                try Task.checkCancellation()
                var segments: [DiarizationSegmentSnapshot] = []
                while let input = await inbox.next() {
                    guard fence.isCurrent else { throw CancellationError() }
                    let labels: [LiveAttribution]
                    switch input {
                    case .audio(let chunk): labels = try await session.ingest(chunk)
                    case .final(let segment):
                        segments.append(segment)
                        labels = await session.noteFinal(segmentID: segment.id, tStart: segment.tStart, tEnd: segment.tEnd)
                    }
                    try Task.checkCancellation()
                    if !labels.isEmpty {
                        await MainActor.run { if fence.isCurrent { onLabels(labels) } }
                    }
                }
                guard fence.isCurrent else { throw CancellationError() }
                let result = try await session.finalize()
                try Task.checkCancellation()
                guard fence.isCurrent else { throw CancellationError() }
                completion.finish(.init(diarization: result, segments: segments))
            } catch {
                if !(error is CancellationError) {
                    Logger(subsystem: "io.macapy.app", category: "MeetingPipeline")
                        .error("optional diarization failed: \(String(describing: type(of: error)), privacy: .public)")
                }
                if fence.invalidate() { await onUnavailable() }
                inbox.cancel()
                completion.finish(nil)
            }
        }
    }

    func enqueueAudio(_ chunk: AudioChunk) { if !inbox.append(.audio(chunk)) { disable() } }
    func enqueueFinal(_ segment: DiarizationSegmentSnapshot) { if !inbox.append(.final(segment)) { disable() } }
    func finishInput() { inbox.finish() }
    var droppedAudio: Int { inbox.droppedAudio }
    func result(grace: Duration) async -> DiarizationWorkerResult? { await completion.wait(grace: grace) }

    func disable() {
        if fence.invalidate() { Task { @MainActor [onUnavailable] in onUnavailable() } }
        inbox.cancel()
        completion.finish(nil)
        task.cancel()
    }

    /// Successful teardown fences the UI without reporting an optional error.
    func close() {
        fence.invalidate()
        inbox.cancel()
        task.cancel()
    }
}
