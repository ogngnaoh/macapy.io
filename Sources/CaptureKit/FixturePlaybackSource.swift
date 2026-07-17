import AVFoundation

/// A real `AudioCaptureSource` that plays a fixture wav back in real time
/// instead of live hardware (slice-05 doc decision 4). Shared by the latency
/// harness executable and its pacing regression test — same conformance
/// `MicCapture`/`SystemAudioCapture` use, so the harness measures the real
/// pipeline, not a shortcut.
///
/// Pacing: reads ~`chunkDuration` of audio at a time, converts it via
/// `BufferConverter` (mirroring the live capture path), and sleeps against a
/// `ContinuousClock` timeline so N seconds of fixture audio take ≈N wall
/// seconds to yield — not "as fast as the disk can read."
public actor FixturePlaybackSource: AudioCaptureSource {
    public nonisolated let source: AudioSource

    private let fixtureURL: URL
    private let chunkDuration: TimeInterval
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private var state: PlaybackState?
    private var playbackTask: Task<Void, Never>?

    public init(fixtureURL: URL, chunkDuration: TimeInterval = 0.1, source: AudioSource = .mic) {
        self.fixtureURL = fixtureURL
        self.chunkDuration = chunkDuration
        self.source = source
    }

    public func start(format: AVAudioFormat) async throws -> AsyncStream<AudioChunk> {
        let file = try AVAudioFile(forReading: fixtureURL)
        let readFormat = file.processingFormat
        let converter = try BufferConverter(from: readFormat, to: format)
        let framesPerChunk = max(
            1, AVAudioFrameCount((chunkDuration * readFormat.sampleRate).rounded())
        )

        let (stream, continuation) = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = continuation
        let state = PlaybackState()
        self.state = state

        // Box every non-Sendable I/O object (AVAudioFile, BufferConverter,
        // AVAudioFormat — the codebase's standing note is that AVAudioFormat
        // is non-Sendable and must be reconstructed per source) so the
        // detached playback loop can own them without hopping back onto this
        // actor per chunk. Same shape as `MicCapture.ConverterBox`: the loop
        // is this box's only reader after creation.
        let resources = PlaybackResources(file: file, converter: converter, readFormat: readFormat)

        // The loop runs detached from this actor (mirrors MicCapture's
        // real-time tap running off-actor): it only touches the
        // lock-protected `state` box and the Sendable continuation/
        // resources, so it never needs to hop back onto the actor mid-chunk.
        // `pause()`/`resume()`/`stop()` (actor-isolated) flip `state`'s
        // flags; `stop()` also finishes the continuation directly for a
        // deterministic end instead of waiting for the loop to notice
        // (`AsyncStream.Continuation.finish()` is idempotent, so the loop's
        // own trailing `finish()` is a harmless no-op if `stop()` already
        // ran).
        let clock = ContinuousClock()
        playbackTask = Task.detached {
            let startInstant = clock.now
            var elapsed: TimeInterval = 0
            loop: while !state.isStopped {
                while state.isPaused {
                    if state.isStopped { break loop }
                    try? await Task.sleep(for: .milliseconds(20))
                }
                if state.isStopped { break }

                guard let inputBuffer = AVAudioPCMBuffer(
                    pcmFormat: resources.readFormat, frameCapacity: framesPerChunk
                ) else { break }
                do {
                    try resources.file.read(into: inputBuffer, frameCount: framesPerChunk)
                } catch {
                    break
                }
                if inputBuffer.frameLength == 0 { break }  // end of file

                guard let converted = try? resources.converter.convert(inputBuffer) else { break }

                // Sleep to this chunk's OWN end-time *before* yielding it —
                // not after. A chunk covering audio up to position kΔ must
                // not be observable before wall-clock has actually reached
                // kΔ; yielding first and sleeping after (the original,
                // buggy order) delivered every chunk ~one whole
                // `chunkDuration` early throughout the entire stream, not
                // just at startup (root cause of the slice-05
                // negative-latency blocker — see FixturePlaybackSourceTests'
                // chunksAreNotDeliveredBeforeTheirOwnAudioDurationHasElapsed).
                elapsed += Double(inputBuffer.frameLength) / resources.readFormat.sampleRate
                let target = startInstant.advanced(by: .seconds(elapsed))
                let now = clock.now
                if target > now {
                    try? await clock.sleep(until: target)
                }

                continuation.yield(AudioChunk(buffer: converted, time: nil))

                if inputBuffer.frameLength < framesPerChunk { break }  // short read == EOF
            }
            continuation.finish()
        }

        return stream
    }

    public func pause() async {
        state?.paused = true
    }

    public func resume() async {
        state?.paused = false
    }

    public func stop() async {
        state?.stopped = true
        continuation?.finish()
        continuation = nil
        playbackTask?.cancel()
        playbackTask = nil
    }

    /// Non-Sendable I/O objects the detached playback loop owns exclusively
    /// after `start()` hands them off — `@unchecked Sendable` because the
    /// compiler can't prove that from `AVAudioFile`/`BufferConverter`'s types
    /// alone, but only the loop ever touches them.
    private final class PlaybackResources: @unchecked Sendable {
        let file: AVAudioFile
        let converter: BufferConverter
        let readFormat: AVAudioFormat

        init(file: AVAudioFile, converter: BufferConverter, readFormat: AVAudioFormat) {
            self.file = file
            self.converter = converter
            self.readFormat = readFormat
        }
    }

    /// Lock-protected pause/stop flags the detached playback loop polls
    /// without hopping back onto the actor — same pattern as
    /// `PlaybackResources` above / `MicCapture.ConverterBox`.
    private final class PlaybackState: @unchecked Sendable {
        private let lock = NSLock()
        private var _paused = false
        private var _stopped = false

        var paused: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _paused }
            set { lock.lock(); _paused = newValue; lock.unlock() }
        }
        var stopped: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _stopped }
            set { lock.lock(); _stopped = newValue; lock.unlock() }
        }
        var isPaused: Bool { paused }
        var isStopped: Bool { stopped }
    }
}
