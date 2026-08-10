import Foundation
import PersistKit
import ProviderKit
import ProviderTestSupport
import Testing
import TranscribeKit

@testable import AppShell

private struct M3LivePipelineReport: Codable, Sendable, Equatable {
    let samples: Int
    let p95Milliseconds: Double
    let maximumMilliseconds: Double
    let classifierModel: String
    let generationModel: String
    let sensitivity: String
    let estimatedCalls: Int
    let estimatedCostUSD: Double
}

private enum M3LivePipelineError: Error {
    case timedOut(String)
}

/// Author-machine evidence for the actual AppShell path. Unlike the AgentKit
/// stage timings, each sample starts at a finalized `TranscriptTurn` entering
/// `LiveCopilotModel.receive` and stops only when a non-empty card is observable
/// by the panel. No diagnostics implementation seam is involved.
@MainActor
@Suite(.serialized, .enabled(if: LiveCredentials.hasDeepSeek))
struct M3LivePipelinePerformanceTests {
    @Test func triggerToFirstVisibleTokenP95IsUnderThreeSeconds() async throws {
        let key = try #require(LiveCredentials.deepSeekKey)
        let profile = EndpointProfile.deepSeek
        let model = LiveCopilotModel()
        model.beginMeeting(
            provider: OpenAICompatibleClient(profile: profile, apiKey: key),
            fastModel: profile.fastModel,
            deepModel: profile.deepModel,
            settings: LiveAISettings(
                aiFeaturesEnabled: true,
                sensitivity: .quiet,
                preferredName: "Hoang"
            )
        )
        defer { model.stopMeeting() }

        let prompts = [
            "Hoang, can you summarize the main migration risk for us?",
            "Hoang, what date should we use for the customer rollout?",
            "Can you explain why the backfill must finish first, Hoang?",
            "Hoang, which launch option do you recommend?",
            "Is the API change backward compatible, Hoang?",
            "Hoang, how much engineering time does the fix require?",
            "What do you need from design before shipping, Hoang?",
            "Hoang, do you agree that Friday is a safe release date?",
            "Can you walk us through the rollback plan, Hoang?",
            "Hoang, where is the current latency regression coming from?",
            "Would you answer the security question, Hoang?",
            "Hoang, what is blocking the database migration?",
            "Can you confirm whether your service is ready, Hoang?",
            "Hoang, why did the canary fail last night?",
            "Which metric should be the launch gate, Hoang?",
            "Hoang, are you comfortable owning the incident review?",
            "Could you clarify the two estimates, Hoang?",
            "Hoang, what should we tell support about the outage?",
            "Can you give us your decision on caching, Hoang?",
            "Hoang, when can your team start the integration test?",
        ]
        var samples: [Double] = []

        for (index, prompt) in prompts.enumerated() {
            let started = ContinuousClock.now
            await model.receive(
                TranscriptTurn(
                    source: .system,
                    text: prompt,
                    segmentIDs: [UUID()],
                    tStart: Double(index * 46),
                    tEnd: Double(index * 46 + 1)
                ),
                userSpeaking: false,
                now: Date(timeIntervalSince1970: 1_800_000_000 + Double(index * 46))
            )
            let firstVisible = try await waitForFirstVisibleCard(
                model,
                started: started,
                timeout: .seconds(10)
            )
            samples.append(firstVisible)
            try await waitForCompletedCard(model, timeout: .seconds(10))
            #expect(model.card?.action == .suggestAnswer)
            #expect(model.card?.requested == false)
            model.dismissCard()
            #expect(model.card == nil)
            await Task.yield()
        }

        let report = M3LivePipelineReport(
            samples: samples.count,
            p95Milliseconds: nearestRankP95(samples),
            maximumMilliseconds: samples.max() ?? 0,
            classifierModel: profile.fastModel,
            generationModel: profile.deepModel,
            sensitivity: LiveAISensitivity.quiet.rawValue,
            estimatedCalls: samples.count * 2,
            estimatedCostUSD: estimatedCostUSD(samples: samples.count)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(report)
        print("M3_EVIDENCE_LIVE_APPSHELL_G2=\(String(decoding: data, as: UTF8.self))")

        #expect(report.samples == 20, "twenty fixed samples make nearest-rank p95 meaningful")
        #expect(report.estimatedCalls == 40)
        #expect(report.estimatedCostUSD < 0.25)
        #expect(report.p95Milliseconds < 3_000)
    }

    private func waitForFirstVisibleCard(
        _ model: LiveCopilotModel,
        started: ContinuousClock.Instant,
        timeout: Duration
    ) async throws -> Double {
        while ContinuousClock.now - started < timeout {
            if let text = model.card?.text, !text.isEmpty {
                return milliseconds(ContinuousClock.now - started)
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw M3LivePipelineError.timedOut("first visible card")
    }

    private func waitForCompletedCard(
        _ model: LiveCopilotModel,
        timeout: Duration
    ) async throws {
        let started = ContinuousClock.now
        while ContinuousClock.now - started < timeout {
            if model.card?.isStreaming == false { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw M3LivePipelineError.timedOut("completed proactive card")
    }

    private func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1e15
    }

    private func nearestRankP95(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = Int((0.95 * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }

    private func estimatedCostUSD(samples: Int) -> Double {
        let pricing = PricingTable.defaults
        let classifier = pricing.estimatedCostUSD(
            model: EndpointProfile.deepSeek.fastModel,
            usage: TokenUsage(
                promptTokens: 900,
                cachedTokens: 0,
                completionTokens: 96
            )
        )!
        let generation = pricing.estimatedCostUSD(
            model: EndpointProfile.deepSeek.deepModel,
            usage: TokenUsage(
                promptTokens: 1_500,
                cachedTokens: 0,
                completionTokens: 160
            )
        )!
        return Double(samples) * (classifier + generation)
    }
}
