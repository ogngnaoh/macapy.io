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
/// **Slice-3 Phase A (this commit) is deliberately minimal:** it builds and
/// starts the whole tap → aggregate → IOProc chain so the first session start
/// triggers the system-audio TCC prompt (`NSAudioCaptureUsageDescription` /
/// `kTCCServiceAudioCapture`), but the IOProc is a no-op and the audio stream
/// yields nothing. The real IOProc → `BufferConverter` → yield path, plus
/// callback-safe teardown ordering, lands in Phase B under the critic's review.
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
        // `format` is the analyzer's preferred format (16kHz Int16 mono). Phase A
        // accepts it but does not convert yet — no chunks are produced. Phase B
        // converts the tap's native format to this via BufferConverter.
        _ = format

        let (tap, tapUUID) = try createProcessTap()
        self.tapID = tap
        do {
            let aggregate = try createAggregateDevice(tapUUID: tapUUID)
            self.aggregateID = aggregate

            // The IOProc runs on a real-time audio thread — it must not touch
            // actor state or `self`. Phase A: no-op (return without reading).
            var procID: AudioDeviceIOProcID?
            let createStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate, nil) {
                _, _, _, _, _ in
                // Phase B: wrap inInputData in an AVAudioPCMBuffer, convert, yield.
            }
            guard createStatus == noErr, let procID else {
                throw CaptureError.processTapFailed(stage: "AudioDeviceCreateIOProcID", status: createStatus)
            }
            self.ioProcID = procID

            let startStatus = AudioDeviceStart(aggregate, procID)
            guard startStatus == noErr else {
                throw CaptureError.processTapFailed(stage: "AudioDeviceStart", status: startStatus)
            }
        } catch {
            // Roll back anything already created so a partial start leaves no
            // orphaned Core Audio objects behind.
            teardownCoreAudio()
            throw error
        }

        running = true
        let (stream, continuation) = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = continuation
        log.info("system-audio tap started (Phase A: no chunks yielded yet)")
        return stream
    }

    public func pause() async {
        guard running, aggregateID != AudioObjectID(kAudioObjectUnknown), let ioProcID else { return }
        AudioDeviceStop(aggregateID, ioProcID)
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

    /// Tears down IOProc → aggregate device → tap, in outside-in order, ignoring
    /// individual failures (best-effort cleanup). Phase B hardens the ordering
    /// against in-flight callbacks.
    private func teardownCoreAudio() {
        if aggregateID != AudioObjectID(kAudioObjectUnknown), let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
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
}
