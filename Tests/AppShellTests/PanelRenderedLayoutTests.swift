import AgentKit
import AppKit
import PersistKit
import ProviderKit
import SwiftUI
import Testing
import TranscribeKit

@testable import AppShell

private struct LayoutProvider: LLMProvider {
    static let answer = String(repeating: "The beta launches June 18. Review the rollback plan before inviting the remaining teams. ", count: 30)

    func stream(_ request: CompletionRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.token(Self.answer))
            continuation.yield(.completed(Completion(finishReason: "stop", usage: nil)))
            continuation.finish()
        }
    }

    func completeReportingUsage<T: Decodable>(
        _ request: CompletionRequest, as type: T.Type
    ) async throws -> CompletedCall<T> {
        try await SampleProvider().completeReportingUsage(request, as: type)
    }
}

/// Measures real SwiftUI layout in an unshown native window. A constants-only
/// test missed the max-height ScrollView accepting a zero-height proposal.
@Suite(.serialized)
@MainActor
struct PanelRenderedLayoutTests {
    @Test(arguments: [false, true])
    func longAnswerKeepsAViewportAndLeavesTranscriptAndControlsVisible(showQuery: Bool) async throws {
        _ = NSApplication.shared
        let session = SessionController()
        let transcript = TranscriptStore()
        let copilot = LiveCopilotModel()
        session.start()
        copilot.beginMeeting(
            meetingID: UUID(), provider: LayoutProvider(), fastModel: "layout", deepModel: "layout",
            settings: LiveAISettings(sensitivity: .off)
        )
        defer { copilot.stopMeeting() }
        // Isolate the requested answer from background summary generation;
        // this is a layout test, not a classifier/summary scheduling test.
        await copilot.setAutomaticSuppressed(true)
        for segment in SampleScenario.segments {
            transcript.apply(.final(segment), from: segment.source)
            await copilot.receive(
                TranscriptTurn(id: segment.id, source: segment.source, text: segment.text,
                               segmentIDs: [segment.id], tStart: segment.tStart, tEnd: segment.tEnd),
                userSpeaking: false
            )
        }
        // Commit authoritative admission state after the initial stream
        // projection; don't race an initial idle event with the button action.
        await copilot.applyLiveSettings(LiveAISettings(sensitivity: .off))
        if showQuery {
            copilot.requestAsk()
            copilot.queryText = "What should the team review before the beta launch and before inviting all remaining teams?"
            #expect(await copilot.submitAsk())
            session.pause()
            session.storageWarning = "Storage is unavailable. Recent text is held temporarily in memory while capture continues. Free disk space or stop the meeting."
        } else {
            // Transcript events are projected asynchronously; earlier times
            // can still be queued after the final receive returns.
            for _ in 0..<100 where !copilot.canCatchUp || copilot.latestTranscriptTime < 154 {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(copilot.canCatchUp)
            copilot.requestCatchUp()
        }
        for _ in 0..<100 where copilot.card?.isStreaming != false {
            try await Task.sleep(for: .milliseconds(10))
        }
        let cardText = try #require(copilot.card?.text)
        #expect(copilot.card?.isStreaming == false)
        // The generator intentionally clamps Catch Up and Ask to different
        // word budgets. Either completed result must still overflow this view.
        #expect(cardText.count >= 300)
        #expect(LayoutProvider.answer.hasPrefix(cardText))

        var frames: [PanelView.LayoutRegion: CGRect] = [:]
        let host = NSHostingView(rootView: PanelView(onLayout: { frames[$0] = $1 })
            .environment(session).environment(transcript).environment(copilot))
        host.sizingOptions = []
        let bounds = CGRect(x: 0, y: 0, width: 340, height: 470)
        let window = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = bounds
        defer { window.close() }
        let required: Set<PanelView.LayoutRegion> = showQuery
            ? [.transcript, .copilot, .answerViewport, .answerContent, .query, .footer]
            : [.transcript, .copilot, .answerViewport, .answerContent, .footer]
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if required.isSubset(of: Set(frames.keys)) { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        let answer = try #require(frames[.answerViewport])
        let content = try #require(frames[.answerContent])
        let transcriptFrame = try #require(frames[.transcript])
        let card = try #require(frames[.copilot])
        #expect(answer.height >= 80, "The answer must have readable height, even with a long transcript.")
        #expect(content.height > answer.height, "Long answers remain scrollable instead of truncating their text.")
        #expect(transcriptFrame.height >= 96)
        #expect(transcriptFrame.maxY <= card.minY + 1)
        #expect(answer.minY >= card.minY && answer.maxY <= card.maxY)
        for region in required.subtracting([.answerContent]) {
            let frame = try #require(frames[region])
            #expect(frame.minY >= -1 && frame.maxY <= 471, "\(region) frame \(frame) must remain inside the fixed panel.")
            #expect(frame.height > 0)
        }
        if showQuery {
            let query = try #require(frames[.query])
            #expect(query.minY >= card.maxY - 1)
        }
    }

    @Test func speakerNamesDoNotCreateExtraTranscriptLines() {
        _ = NSApplication.shared
        func height(for speaker: String) -> CGFloat {
            let view = NSHostingView(rootView: TranscriptLineView(
                speaker: speaker, isYou: false, text: "Ready.", isVolatile: false
            ).frame(width: 340))
            return view.fittingSize.height
        }
        let short = height(for: "You")
        #expect(short > 0)
        #expect(height(for: "Morgan") <= short + 1)
        #expect(height(for: "Alexandria Montgomery") <= short + 1)
    }
}
