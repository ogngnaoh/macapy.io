import AVFoundation
import CoreAudio
import os

/// System-audio capture via a Core Audio process tap (macOS 26). Builds a
/// global **mono mixdown** tap that excludes our own process, wraps it in a
/// private aggregate device, and runs an IOProc so the audio the Mac is playing
/// (the meeting) flows in. The tap is *pre-output* (`.unmuted`), so the user
/// still hears the call and capture works with headphones connected (milestone
/// exit criterion 3) — nothing about output routing changes.
///
/// The IOProc runs on a Core Audio real-time thread: it touches no actor state
/// and no `self`, only a boxed converter + the (Sendable) stream continuation —
/// the same discipline as `MicCapture`. `BufferConverter` allocates a fresh
/// output buffer per call, so every yielded chunk is a buffer the producer will
/// never look at again (the `AudioChunk` ownership rule holds by construction).
public actor SystemAudioCapture: AudioCaptureSource {
    public nonisolated let source: AudioSource = .system

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private var running = false

    private let log = Logger(subsystem: "io.macapy.app", category: "SystemAudioCapture")

    public init() {}

    public func start(format: AVAudioFormat) async throws -> AsyncStream<AudioChunk> {
        // 1) Create the process tap (excludes our own process).
        let (tap, tapUUID) = try createProcessTap()
        self.tapID = tap

        do {
            // 2) The tap's native format is what the IOProc delivers; convert
            //    from it to the analyzer's requested `format` (16kHz Int16 mono).
            let nativeFormat = try tapStreamFormat(tap)
            let converter = try BufferConverter(from: nativeFormat, to: format)

            // 3) Aggregate device wrapping the tap, so we can run an IOProc.
            let aggregate = try createAggregateDevice(tapUUID: tapUUID)
            self.aggregateID = aggregate

            // 4) The stream the IOProc feeds. Created before the IOProc so the
            //    callback has a live continuation to yield into.
            let (stream, continuation) = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .unbounded)
            self.continuation = continuation

            // 5) IOProc. The block runs on a real-time audio thread and captures
            //    only `context` (an @unchecked Sendable box whose sole user, after
            //    start, is that thread) — never `self` or actor state.
            let context = IOProcContext(
                converter: converter, nativeFormat: nativeFormat, continuation: continuation)
            var procID: AudioDeviceIOProcID?
            let createStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate, nil) {
                _, inInputData, _, _, _ in
                context.handle(inInputData)
            }
            guard createStatus == noErr, let procID else {
                throw CaptureError.processTapFailed(stage: "AudioDeviceCreateIOProcID", status: createStatus)
            }
            self.ioProcID = procID

            // 6) Start pulling audio (this is where the tap actually runs).
            let startStatus = AudioDeviceStart(aggregate, procID)
            guard startStatus == noErr else {
                throw CaptureError.processTapFailed(stage: "AudioDeviceStart", status: startStatus)
            }

            running = true
            log.info("system-audio tap started")
            return stream
        } catch {
            // Roll back everything already created so a partial start leaves no
            // orphaned Core Audio objects and no dangling continuation.
            teardownCoreAudio()
            continuation?.finish()
            continuation = nil
            throw error
        }
    }

    public func pause() async {
        guard running, aggregateID != AudioObjectID(kAudioObjectUnknown), let ioProcID else { return }
        AudioDeviceStop(aggregateID, ioProcID)  // returns once the IOProc is no longer running
        running = false
    }

    public func resume() async {
        guard !running, aggregateID != AudioObjectID(kAudioObjectUnknown), let ioProcID else { return }
        if AudioDeviceStart(aggregateID, ioProcID) == noErr {
            running = true
        }
    }

    public func stop() async {
        teardownCoreAudio()
        // Finish only after the IOProc is guaranteed stopped (teardownCoreAudio
        // calls AudioDeviceStop first), so no yield can race the finish.
        continuation?.finish()
        continuation = nil
    }

    // MARK: - Core Audio setup

    /// Builds a private mono global-mixdown tap that excludes our own process,
    /// then asks Core Audio to create it. Returns the tap's object ID and its
    /// UID string (the description's UUID *is* the tap's UID, used to reference
    /// it from the aggregate device's tap list).
    private func createProcessTap() throws -> (AudioObjectID, String) {
        let ownProcess = ownProcessObjectID()
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: ownProcess.map { [$0] } ?? [])
        description.name = "macapy system-audio tap"
        description.isPrivate = true          // visible only to us
        description.muteBehavior = .unmuted   // do not mute the user's playback

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &newTapID)
        guard status == noErr, newTapID != AudioObjectID(kAudioObjectUnknown) else {
            throw CaptureError.processTapFailed(stage: "AudioHardwareCreateProcessTap", status: status)
        }
        return (newTapID, description.uuid.uuidString)
    }

    /// Wraps `tapUUID` in a private, auto-starting aggregate device we can run an
    /// IOProc on.
    private func createAggregateDevice(tapUUID: String) throws -> AudioObjectID {
        let uid = UUID().uuidString
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "macapy-system-audio",
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [],
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapUUID]
            ],
        ]
        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &newAggregateID)
        guard status == noErr, newAggregateID != AudioObjectID(kAudioObjectUnknown) else {
            throw CaptureError.processTapFailed(stage: "AudioHardwareCreateAggregateDevice", status: status)
        }
        return newAggregateID
    }

    /// Tears down IOProc → aggregate device → tap, in outside-in order.
    ///
    /// Ordering is the safety-critical part: `AudioDeviceStop` returns only once
    /// the IOProc is no longer executing, so after it no callback can touch the
    /// converter or continuation; only then do we destroy the IOProc, the
    /// aggregate device, and finally the tap. Best-effort — individual failures
    /// are ignored (there is nothing to recover to) but the object IDs are
    /// cleared so a double `stop()` is a no-op.
    private func teardownCoreAudio() {
        if aggregateID != AudioObjectID(kAudioObjectUnknown), let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)          // waits out any in-flight callback
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        running = false
    }

    // MARK: - Core Audio queries

    /// The tap's native stream format — the format the IOProc's input buffers
    /// arrive in (typically 32-bit float mono at the output device's rate).
    private func tapStreamFormat(_ tap: AudioObjectID) throws -> AVAudioFormat {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd)
        guard status == noErr, asbd.mSampleRate > 0,
              let format = AVAudioFormat(streamDescription: &asbd) else {
            throw CaptureError.processTapFailed(stage: "kAudioTapPropertyFormat", status: status)
        }
        return format
    }

    /// Our own process's Core Audio process-object ID, so the global tap can
    /// exclude us (we must not capture our own output). Returns nil if the
    /// translation fails — the tap is then simply not self-excluding.
    private func ownProcessObjectID() -> AudioObjectID? {
        var pid = getpid()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var processObject = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &pid) { pidPtr in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<pid_t>.size), pidPtr, &size, &processObject)
        }
        guard status == noErr, processObject != AudioObjectID(kAudioObjectUnknown) else {
            return nil
        }
        return processObject
    }

    /// Carries the non-Sendable converter + format across the real-time IOProc
    /// block boundary. The audio thread is its only user once capture is
    /// running, so `@unchecked Sendable` is sound (same rationale as
    /// `MicCapture.ConverterBox`). `handle` runs entirely on that thread.
    private final class IOProcContext: @unchecked Sendable {
        let converter: BufferConverter
        let nativeFormat: AVAudioFormat
        let continuation: AsyncStream<AudioChunk>.Continuation

        init(
            converter: BufferConverter,
            nativeFormat: AVAudioFormat,
            continuation: AsyncStream<AudioChunk>.Continuation
        ) {
            self.converter = converter
            self.nativeFormat = nativeFormat
            self.continuation = continuation
        }

        /// Real-time thread: wrap the incoming buffer list (no copy), convert to
        /// the target format (a fresh owned buffer), and yield it. The no-copy
        /// wrapper is only read synchronously inside `convert`; the underlying
        /// buffer-list memory is owned by Core Audio and valid for the callback.
        func handle(_ inInputData: UnsafePointer<AudioBufferList>) {
            guard let input = AVAudioPCMBuffer(pcmFormat: nativeFormat, bufferListNoCopy: inInputData),
                  input.frameLength > 0,
                  let converted = try? converter.convert(input) else { return }
            continuation.yield(AudioChunk(buffer: converted, time: nil))
        }
    }
}
