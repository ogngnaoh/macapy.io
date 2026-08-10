import Foundation
import ProviderKit
import ProviderTestSupport
import Testing

@testable import AgentKit

private struct M3LiveQualityReport: Codable, Sendable, Equatable {
    let provider: String
    let classifierModel: String
    let temperature: Double
    let transientRetries: Int
    let estimatedCalls: Int
    let estimatedCostUSD: Double
    let quality: M3QualityScore
}

private struct M3LiveLatencyEvidenceReport: Codable, Sendable, Equatable {
    let provider: String
    let classifierModel: String
    let generationModel: String
    let temperature: Double
    let scenarioID: String
    let estimatedCalls: Int
    let estimatedCostUSD: Double
    let latency: M3LatencyReport
}

private enum M3LiveEvidenceRunError: Error {
    case provider(String)
    case unexpected
}

private struct TimedClassifierResult: Sendable {
    let decision: ClassifierDecision
    let milliseconds: Double
    let retries: Int
}

/// Credential-gated and serialized so the corpus and timing authorities never
/// become a request storm. Quality and service timing are separate tests: a
/// transient latency incident can be rerun without paying for 130 unrelated
/// quality calls, while neither gate is weakened or averaged across attempts.
@Suite(.serialized, .enabled(if: LiveCredentials.hasDeepSeek))
struct M3LiveEvidenceTests {
    @Test func realDeepSeekFrozenCorpusMeetsQuietGuarantee() async throws {
        let key = try #require(LiveCredentials.deepSeekKey)
        let corpus = try M3Corpus.load()
        let profile = EndpointProfile.deepSeek
        let classifier = CopilotClassifier(
            provider: OpenAICompatibleClient(profile: profile, apiKey: key),
            model: profile.fastModel
        )
        let configuration = CopilotConfiguration(
            aiFeaturesEnabled: true,
            proactiveEnabled: true,
            confidenceThreshold: M3Evidence.quietThreshold,
            preferredName: "Hoang",
            cooldownSeconds: 45
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var observations: [M3ObservedDecision] = []
        var transientRetries = 0

        for entry in corpus {
            let gate = CopilotGate.evaluate(
                turn: entry.turn,
                configuration: configuration,
                state: CopilotGateState(),
                now: now
            )
            switch gate {
            case .allowed:
                let timed = try await classifyWithRetry(
                    classifier,
                    turn: entry.turn,
                    preferredName: configuration.preferredName
                )
                transientRetries += timed.retries
                observations.append(M3ObservedDecision(
                    id: entry.id,
                    expected: entry.expected,
                    observed: M3Evidence.admittedAction(timed.decision)
                ))
            case .rejected(.userSource):
                observations.append(M3ObservedDecision(
                    id: entry.id,
                    expected: entry.expected,
                    observed: nil
                ))
            case .rejected(let reason):
                Issue.record("Unexpected live gate rejection for \(entry.id): \(reason)")
            }
        }

        let quality = M3QualityScore.score(observations)
        let report = M3LiveQualityReport(
            provider: profile.id,
            classifierModel: profile.fastModel,
            temperature: 0,
            transientRetries: transientRetries,
            estimatedCalls: 130,
            estimatedCostUSD: M3Evidence.estimatedCostUSD(
                model: profile.fastModel,
                promptTokens: 900,
                completionTokens: CopilotClassifier.outputTokenCeiling,
                calls: 130
            ),
            quality: quality
        )
        try M3Evidence.printJSON("live_quality", report)

        #expect(report.estimatedCalls == 130)
        #expect(report.estimatedCostUSD < 0.25)
        #expect(quality.passesQuietGuarantee)
        #expect(transientRetries <= 5, "more than five transient retries is an upstream service incident")
    }

    @Test func realDeepSeekStageFirstTokenBudgets() async throws {
        let key = try #require(LiveCredentials.deepSeekKey)
        let profile = EndpointProfile.deepSeek
        let client = OpenAICompatibleClient(profile: profile, apiKey: key)
        let classifier = CopilotClassifier(provider: client, model: profile.fastModel)
        let generator = CopilotGenerator(provider: client, model: profile.deepModel)
        let scenario = try #require(M3Corpus.load().first { $0.id == "Q01" })
        var classifierMilliseconds: [Double] = []
        var generationMilliseconds: [Double] = []
        var g2Milliseconds: [Double] = []
        var transientRetries = 0
        let grounding = CopilotTurn(
            source: .system,
            text: "The migration is gated on reconciliation, with rollback documented before cutover.",
            tStart: 0,
            tEnd: 1
        )

        for _ in 0..<20 {
            let classified = try await classifyWithRetry(
                classifier,
                turn: scenario.turn,
                preferredName: "Hoang"
            )
            transientRetries += classified.retries
            let generated = try await firstTokenWithRetry {
                generator.suggestedAnswer(
                    turns: [grounding, scenario.turn],
                    target: classified.decision.target ?? scenario.text
                )
            }
            transientRetries += generated.retries
            classifierMilliseconds.append(classified.milliseconds)
            generationMilliseconds.append(generated.milliseconds)
            g2Milliseconds.append(classified.milliseconds + generated.milliseconds)
        }

        var catchUpMilliseconds: [Double] = []
        let catchUpTurns = (0..<12).map { index in
            CopilotTurn(
                source: index.isMultiple(of: 4) ? .mic : .system,
                text: "Turn \(index): reconciliation remains the cutover gate and the rollback owner is confirmed.",
                tStart: Double(index * 8),
                tEnd: Double(index * 8 + 7)
            )
        }
        for _ in 0..<5 {
            let result = try await firstTokenWithRetry {
                generator.catchUp(turns: catchUpTurns)
            }
            transientRetries += result.retries
            catchUpMilliseconds.append(result.milliseconds)
        }

        let latency = M3LatencyReport(
            classifierSamples: classifierMilliseconds.count,
            classifierP95Milliseconds: M3Evidence.nearestRankP95(classifierMilliseconds),
            generationSamples: generationMilliseconds.count,
            generationFirstTokenP95Milliseconds: M3Evidence.nearestRankP95(generationMilliseconds),
            g2Samples: g2Milliseconds.count,
            g2P95Milliseconds: M3Evidence.nearestRankP95(g2Milliseconds),
            catchUpSamples: catchUpMilliseconds.count,
            catchUpFirstTokenMaximumMilliseconds: catchUpMilliseconds.max() ?? 0,
            transientRetries: transientRetries
        )
        let report = M3LiveLatencyEvidenceReport(
            provider: profile.id,
            classifierModel: profile.fastModel,
            generationModel: profile.deepModel,
            temperature: 0,
            scenarioID: scenario.id,
            estimatedCalls: 45,
            estimatedCostUSD:
                M3Evidence.estimatedCostUSD(
                    model: profile.fastModel,
                    promptTokens: 900,
                    completionTokens: CopilotClassifier.outputTokenCeiling,
                    calls: 20
                )
                + M3Evidence.estimatedCostUSD(
                    model: profile.deepModel,
                    promptTokens: 1_500,
                    completionTokens: CopilotGenerator.shortOutputTokenCeiling,
                    calls: 25
                ),
            latency: latency
        )
        try M3Evidence.printJSON("live_stage_latency", report)

        #expect(report.estimatedCalls == 45)
        #expect(report.estimatedCostUSD < 0.25)
        #expect(latency.classifierSamples == 20)
        #expect(latency.generationSamples == 20)
        #expect(latency.g2Samples == 20)
        #expect(latency.passes)
        #expect(transientRetries <= 5, "more than five transient retries is an upstream service incident")
    }

    private func classifyWithRetry(
        _ classifier: CopilotClassifier,
        turn: CopilotTurn,
        preferredName: String?
    ) async throws -> TimedClassifierResult {
        var retries = 0
        while true {
            let started = ContinuousClock.now
            do {
                let decision = try await classifier.classify(
                    recentTurns: [turn],
                    preferredName: preferredName
                )
                return TimedClassifierResult(
                    decision: decision,
                    milliseconds: M3Evidence.milliseconds(ContinuousClock.now - started),
                    retries: retries
                )
            } catch {
                guard retries < 2, M3Evidence.isTransient(error) else {
                    throw sanitized(error)
                }
                retries += 1
                try await Task.sleep(for: .milliseconds(250 * retries))
            }
        }
    }

    /// Retry only transport/429/5xx classes. The successful attempt retains
    /// the locked latency budget; retries are reported separately as service
    /// flakes and capped, never averaged into a more flattering percentile.
    private func firstTokenWithRetry(
        _ makeStream: () -> AsyncThrowingStream<CopilotTextEvent, Error>
    ) async throws -> (milliseconds: Double, retries: Int) {
        var retries = 0
        while true {
            let started = ContinuousClock.now
            var firstTokenMilliseconds: Double?
            do {
                for try await event in makeStream() {
                    if case .delta(let text) = event,
                       !text.isEmpty,
                       firstTokenMilliseconds == nil
                    {
                        firstTokenMilliseconds = M3Evidence.milliseconds(
                            ContinuousClock.now - started
                        )
                    }
                }
                guard let firstTokenMilliseconds else {
                    throw ProviderError.malformedResponse("live evidence stream produced no answer token")
                }
                return (firstTokenMilliseconds, retries)
            } catch {
                guard retries < 2, M3Evidence.isTransient(error) else {
                    throw sanitized(error)
                }
                retries += 1
                try await Task.sleep(for: .milliseconds(250 * retries))
            }
        }
    }

    /// Endpoint messages can echo meeting content. Live evidence failures
    /// retain only ProviderKit's fixed diagnostic vocabulary.
    private func sanitized(_ error: any Error) -> M3LiveEvidenceRunError {
        guard let provider = error as? ProviderError else { return .unexpected }
        return .provider(provider.logDescription)
    }
}
