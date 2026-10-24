import Foundation
import Testing

@testable import CaptureKit

struct CaptureInterruptionTests {
    @Test func reportsExactlyOneTypedFailurePerGeneration() async {
        let channel = CaptureInterruptionChannel()
        let stream = channel.stream()
        let report = channel.begin(source: .mic)
        report(.conversionFailed)
        report(.resumeFailed)
        var events: [CaptureInterruption] = []
        for await event in stream { events.append(event) }
        #expect(events == [.init(source: .mic, reason: .conversionFailed)])
    }

    @Test func queuedCallbacksFromOldSourceCannotFailNewGeneration() async {
        let channel = CaptureInterruptionChannel()
        let oldStream = channel.stream()
        let old = channel.begin(source: .system)
        channel.end()
        let newStream = channel.stream()
        let current = channel.begin(source: .system)
        old(.routeChanged)
        current(.pauseFailed)
        var oldEvents: [CaptureInterruption] = []
        for await event in oldStream { oldEvents.append(event) }
        var newEvents: [CaptureInterruption] = []
        for await event in newStream { newEvents.append(event) }
        #expect(oldEvents.isEmpty)
        #expect(newEvents == [.init(source: .system, reason: .pauseFailed)])
    }

    @Test func normalStopFinishesWatchersWithoutAnError() async {
        let channel = CaptureInterruptionChannel()
        let stream = channel.stream()
        let reporter = channel.begin(source: .mic)
        channel.end()
        reporter(.routeChanged)
        var events: [CaptureInterruption] = []
        for await event in stream { events.append(event) }
        #expect(events.isEmpty)
    }
}
