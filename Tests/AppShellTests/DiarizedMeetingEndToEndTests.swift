import AVFoundation
import CaptureKit
import DiarizeKit
import Foundation
import PersistKit
import ProviderTestSupport
import Testing
import TranscribeKit

@testable import AppShell

/// Slice-4 check 3 [gated: models] — the deepest oracle: the two-voice
/// fixture played in real time as the them-stream and a single-voice fixture
/// as the mic, through the real `SpeechAnalyzerEngine` and real FluidAudio in
/// the real `MeetingPipeline`. Replaces former live check 7's dev half; the
/// genuinely-real-meeting run folds into dogfooding + the app-complete walk.
///
/// Real-time paced (~70s) — that cost lives only in this model-gated suite,
/// per the re-plan's suite-speed rule.
@Suite(.serialized, .enabled("Requires explicit model opt-in, installed speech/diarization assets, and local fox.wav/two-voices.wav; no downloads") {
    guard TestRunPolicy.runsLocalModels && LocalAudioFixtures.has(["fox.wav", "two-voices.wav"]) && DiarizationModelStore.isInstalled else { return false }
    return await SpeechAnalyzerEngine.assetsAreInstalled(locale: Locale(identifier: "en_US"))
})
struct DiarizedMeetingEndToEndTests {

    private func fixture(_ name: String) throws -> URL {
        try #require(LocalAudioFixtures.url(named: "\(name).wav"))
    }

    @MainActor
    @Test(.timeLimit(.minutes(3)))
    func realPipelineSeparatesTwoThemVoicesAndLeavesMicNull() async throws {
        let store = TranscriptStore()
        let meetingStore = MeetingStore(database: try MacapyDatabase.inMemory())
        let pipeline = MeetingPipeline(
            engine: SpeechAnalyzerEngine(locale: Locale(identifier: "en_US"), assetInstallationPolicy: .installedOnly),
            sources: [
                FixturePlaybackSource(fixtureURL: try fixture("fox"), source: .mic),
                FixturePlaybackSource(fixtureURL: try fixture("two-voices"), source: .system),
            ],
            store: store,
            locale: Locale(identifier: "en_US"),
            makeDiarizer: { DiarizationSession(engine: try FluidAudioDiarizer()) },
            diarizationLease: OptionalDiarizationLease()
        )

        try await pipeline.start(mode: .persistent(meetingStore))
        // Local generation can vary slightly by installed voice version. Play
        // the entire supplied fixture before applying the same stop oracle.
        let fixtureFile = try AVAudioFile(forReading: fixture("two-voices"))
        let duration = Double(fixtureFile.length) / fixtureFile.processingFormat.sampleRate
        try await Task.sleep(for: .seconds(duration + 2))
        let stopStarted = ContinuousClock.now
        let meetingID = try #require(await pipeline.stop())
        let stopDuration = ContinuousClock.now - stopStarted

        // stop() tail: writer flush + diarizer finalize + sweep. Loose bound —
        // a runaway finalize (whole-meeting reprocessing) would blow this.
        #expect(stopDuration < .seconds(15))

        let speakers = try await meetingStore.speakers(for: meetingID)
        #expect(speakers.count >= 2)
        #expect(speakers.prefix(2).map(\.label) == ["S1", "S2"])

        let attributed = try await meetingStore.attributedSegments(for: meetingID)
        let themSpeakerIDs = Set(
            attributed.filter { $0.segment.source == .system }.compactMap(\.speakerID))
        #expect(themSpeakerIDs.count >= 2, "them-segments must carry ≥2 distinct speakers")

        let micSegments = attributed.filter { $0.segment.source == .mic }
        #expect(!micSegments.isEmpty, "mic fixture must have transcribed")
        #expect(micSegments.allSatisfy { $0.speakerID == nil }, "mic segments never get a speaker")

        // The live map labeled at least some them-segments during the meeting.
        #expect(!store.speakerLabels.isEmpty)
    }
}
