import CoreAudio
import Foundation

/// Owned by one SystemAudioCapture actor. Core Audio retains each block until
/// its exact object/address/queue/block registration is removed.
final class AudioRouteObservation {
    private struct Registration {
        let object: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }
    private let queue = DispatchQueue(label: "io.macapy.audio-route")
    private var registrations: [Registration] = []

    init(tapID: AudioObjectID, reporter: CaptureInterruptionChannel.Reporter) throws {
        do {
            try observe(AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDefaultOutputDevice, reporter: reporter)
            try observe(tapID, selector: kAudioTapPropertyFormat, reporter: reporter)
        } catch { stop(); throw error }
    }

    private func observe(_ object: AudioObjectID, selector: AudioObjectPropertySelector,
                         reporter: CaptureInterruptionChannel.Reporter) throws {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { _, _ in reporter(.routeChanged) }
        let status = AudioObjectAddPropertyListenerBlock(object, &address, queue, block)
        guard status == noErr else {
            throw CaptureError.processTapFailed(stage: "AudioObjectAddPropertyListenerBlock", status: status)
        }
        registrations.append(.init(object: object, address: address, block: block))
    }

    func stop() {
        for var registration in registrations {
            AudioObjectRemovePropertyListenerBlock(registration.object, &registration.address, queue, registration.block)
        }
        registrations.removeAll()
    }

    deinit { stop() }
}
