import AVFoundation
import CaptureKit
import CoreMedia
import Foundation
import Testing

/// Slice-4 checks 5, 6 (structural half), and 10b: the bounded fan-out is the
/// memory-watch primitive — drop-oldest with an exact surfaced count, order
/// preserved, evicted audio provably released, zero interference when the
/// consumer keeps up.
struct BoundedFanOutTests {

    private static let format = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!

    /// A chunk tagged with its sequence number via `time` so order and identity
    /// are assertable without touching sample data.
    private func chunk(_ n: Int, frames: AVAudioFrameCount = 8) -> AudioChunk {
        let buffer = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: frames)!
        buffer.frameLength = frames
        return AudioChunk(buffer: buffer, time: CMTime(value: CMTimeValue(n), timescale: 1))
    }

    private func tag(_ chunk: AudioChunk) -> Int {
        Int(chunk.time!.value)
    }

    private final class WeakBox {
        weak var buffer: AVAudioPCMBuffer?
        init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    }

    // MARK: - Check 10b: pass-through under a draining consumer

    @Test func passThroughPreservesOrderWithZeroDropsUnderDrainingConsumer() async {
        let (source, feed) = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .unbounded)
        let out = BoundedAudioFanOut.split(source, branchCount: 1, bound: 4)

        // Lockstep: the producer waits for each chunk to be consumed before
        // feeding the next — "consumer keeps up" as a guarantee, not a hope
        // (`Task.yield()` schedules nothing deterministically).
        let (acks, ackFeed) = AsyncStream<Void>.makeStream(bufferingPolicy: .unbounded)
        let consumer = Task { () -> [Int] in
            var seen: [Int] = []
            for await chunk in out.branches[0] {
                seen.append(tag(chunk))
                ackFeed.yield(())
            }
            ackFeed.finish()
            return seen
        }
        var ackIterator = acks.makeAsyncIterator()
        for n in 0..<500 {
            feed.yield(chunk(n))
            _ = await ackIterator.next()
        }
        feed.finish()

        let seen = await consumer.value
        await out.forwarding.value
        #expect(seen == Array(0..<500))
        #expect(out.drops.total == 0)
    }

    // MARK: - Check 5: stall oracle

    @Test func stalledConsumerDropsOldestExactlyAndResumeDeliversNewestInOrder() async {
        let (source, feed) = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .unbounded)
        let out = BoundedAudioFanOut.split(source, branchCount: 1, bound: 100)

        // No consumer attached: the branch buffer is the only holder.
        for n in 0..<250 { feed.yield(chunk(n)) }
        feed.finish()
        await out.forwarding.value

        #expect(out.drops.count(forBranch: 0) == 150)
        #expect(out.drops.total == 150)

        var seen: [Int] = []
        for await chunk in out.branches[0] { seen.append(tag(chunk)) }
        #expect(seen == Array(150..<250))
    }

    @Test func evictedBuffersAreDeallocated() async {
        let (source, feed) = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .unbounded)
        let out = BoundedAudioFanOut.split(source, branchCount: 1, bound: 10)

        var boxes: [WeakBox] = []
        for n in 0..<50 {
            let c = chunk(n)
            boxes.append(WeakBox(c.buffer))
            feed.yield(c)
        }
        feed.finish()
        await out.forwarding.value

        // Evicted (first 40) must be gone even before the survivors are
        // consumed; the newest 10 are still held by the branch buffer.
        let liveBeforeDrain = boxes.filter { $0.buffer != nil }.count
        #expect(liveBeforeDrain == 10)

        for await _ in out.branches[0] {}
        let liveAfterDrain = boxes.filter { $0.buffer != nil }.count
        #expect(liveAfterDrain == 0)
    }

    // MARK: - Check 6 (structural half): bounded growth at 1h-equivalent scale

    @Test func liveChunksNeverExceedBoundTimesBranchesAcross36kChunks() async {
        let (source, feed) = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .unbounded)
        let branches = 2
        let bound = 100
        let out = BoundedAudioFanOut.split(source, branchCount: branches, bound: bound)

        var boxes: [WeakBox] = []
        boxes.reserveCapacity(36_000)
        for n in 0..<36_000 {
            let c = chunk(n)
            boxes.append(WeakBox(c.buffer))
            feed.yield(c)
        }
        feed.finish()
        await out.forwarding.value

        // Both branches stalled: each retains exactly `bound` newest chunks.
        // The same buffer instance rides both branches (read-only sharing), so
        // the live ceiling is `bound` distinct buffers, not bound × branches —
        // assert the stricter structural bound.
        let live = boxes.filter { $0.buffer != nil }.count
        #expect(live <= bound)
        #expect(out.drops.count(forBranch: 0) == 36_000 - bound)
        #expect(out.drops.count(forBranch: 1) == 36_000 - bound)
    }

    // MARK: - Independent branches + tap

    @Test func branchCountersAreIndependent() async {
        let (source, feed) = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .unbounded)
        let out = BoundedAudioFanOut.split(source, branchCount: 2, bound: 10)

        // Branch 0 drains in lockstep with the producer; branch 1 stalls.
        let (acks, ackFeed) = AsyncStream<Void>.makeStream(bufferingPolicy: .unbounded)
        let drainer = Task {
            for await _ in out.branches[0] { ackFeed.yield(()) }
            ackFeed.finish()
        }
        var ackIterator = acks.makeAsyncIterator()
        for n in 0..<200 {
            feed.yield(chunk(n))
            _ = await ackIterator.next()
        }
        feed.finish()
        await out.forwarding.value
        await drainer.value

        #expect(out.drops.count(forBranch: 0) == 0)
        #expect(out.drops.count(forBranch: 1) == 190)
    }

    @Test func onChunkTapSeesEveryChunkExactlyOnceInOrder() async {
        let (source, feed) = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .unbounded)
        let tapped = TappedTags()
        let out = BoundedAudioFanOut.split(source, branchCount: 1, bound: 5, onChunk: { chunk in
            tapped.append(Int(chunk.time!.value))
        })

        for n in 0..<64 { feed.yield(chunk(n)) }
        feed.finish()
        await out.forwarding.value

        #expect(tapped.values == Array(0..<64))
    }

    private final class TappedTags: @unchecked Sendable {
        private let lock = NSLock()
        private var tags: [Int] = []
        func append(_ n: Int) { lock.withLock { tags.append(n) } }
        var values: [Int] { lock.withLock { tags } }
    }
}
