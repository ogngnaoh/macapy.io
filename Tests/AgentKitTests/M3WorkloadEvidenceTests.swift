import CaptureKit
import Foundation
import ProviderKit
import Testing

@testable import AgentKit

private struct M3WorkloadLine: Codable, Sendable, Equatable {
    let name: String
    let calls: Int
    let model: String
    let promptTokensPerCall: Int
    let completionTokensPerCall: Int
    let estimatedCostUSD: Double
}

private struct M3OneHourCostReport: Codable, Sendable, Equatable {
    let durationMinutes: Int
    let lines: [M3WorkloadLine]
    let totalCalls: Int
    let totalPromptTokens: Int
    let totalCompletionTokens: Int
    let estimatedCostUSD: Double
    let ceilingUSD: Double
}

private struct M3ThreeHourContextReport: Codable, Sendable, Equatable {
    let transcriptTurns: Int
    let transcriptSeconds: Double
    let summaryRefreshes: Int
    let checkedRequests: Int
    let maximumRequestCharacters: Int
    let hardCharacterLimit: Int
    let latestTenRetained: Bool
    let hardFailures: Int
}

private struct ConstantM3Summarizer: RollingSummaryGenerating {
    func summarize(context: CopilotAssembledContext) async throws -> RollingSummary {
        RollingSummary(
            overview: "The team is sequencing a long migration and tracking its launch risks.",
            decisions: ["Cutover remains gated on a clean reconciliation."],
            commitments: [RollingCommitment(
                task: "Maintain the rollback runbook",
                owner: "Hoang",
                deadline: "before cutover"
            )],
            unresolvedQuestions: ["Which window has the lowest customer impact?"]
        )
    }
}

@Suite(.serialized)
struct M3WorkloadEvidenceTests {
    @Test func oneHourScriptedWorkloadStaysBelowTwentyFiveCents() throws {
        let pricing = PricingTable.defaults
        let fast = EndpointProfile.deepSeek.fastModel
        let deep = EndpointProfile.deepSeek.deepModel
        let specs: [(String, Int, String, Int, Int)] = [
            // A deliberately busy hour: one eligible system turn every 30s,
            // every two-minute summary boundary, twelve proactive moments,
            // six explicit requests, and two post-meeting artifact calls.
            ("classifier", 120, fast, 900, CopilotClassifier.outputTokenCeiling),
            ("rolling_summary", 30, fast, 10_500, CopilotContextLimits.summaryOutputTokenCeiling),
            ("suggested_answer", 8, deep, 10_500, CopilotGenerator.shortOutputTokenCeiling),
            ("commitment", 4, deep, 10_500, CopilotGenerator.shortOutputTokenCeiling),
            ("catch_up", 2, deep, 10_500, CopilotGenerator.shortOutputTokenCeiling),
            ("query", 4, deep, 10_500, CopilotGenerator.queryOutputTokenCeiling),
            ("post_meeting_artifact", 2, deep, 15_000, 4_096),
        ]

        let lines = try specs.map { name, calls, model, prompt, completion in
            let perCall = try #require(pricing.estimatedCostUSD(
                model: model,
                usage: TokenUsage(
                    promptTokens: prompt,
                    cachedTokens: 0,
                    completionTokens: completion
                )
            ))
            return M3WorkloadLine(
                name: name,
                calls: calls,
                model: model,
                promptTokensPerCall: prompt,
                completionTokensPerCall: completion,
                estimatedCostUSD: perCall * Double(calls)
            )
        }
        let report = M3OneHourCostReport(
            durationMinutes: 60,
            lines: lines,
            totalCalls: lines.reduce(0) { $0 + $1.calls },
            totalPromptTokens: lines.reduce(0) { $0 + $1.calls * $1.promptTokensPerCall },
            totalCompletionTokens: lines.reduce(0) { $0 + $1.calls * $1.completionTokensPerCall },
            estimatedCostUSD: lines.reduce(0) { $0 + $1.estimatedCostUSD },
            ceilingUSD: 0.25
        )

        try M3Evidence.printJSON("one_hour_cost", report)
        #expect(report.totalCalls == 170)
        #expect(report.estimatedCostUSD <= report.ceilingUSD)
        #expect(report.estimatedCostUSD < 0.20, "leave non-trivial room below the locked $0.25 gate")
        #expect(lines.first { $0.name == "classifier" }?.completionTokensPerCall
            == CopilotClassifier.outputTokenCeiling)
        #expect(lines.first { $0.name == "query" }?.completionTokensPerCall
            == CopilotGenerator.queryOutputTokenCeiling)
    }

    @Test func threeHourFixtureProducesBoundedRequestsWithoutHardFailure() async throws {
        let stablePrefix = "Meeting: three-hour migration review\nPreferred user: Hoang"
        let manager = try CopilotContextManager(stablePrefix: stablePrefix)
        let target = "the production migration decision"
        let question = "What decision and owner does the meeting support?"
        let repeated = String(repeating: "context evidence ", count: 20)
        var turns: [CopilotTurn] = []
        var maximumCharacters = 0
        var checkedRequests = 0
        var refreshes = 0

        func record(_ characterCount: Int) {
            maximumCharacters = max(maximumCharacters, characterCount)
            checkedRequests += 1
        }

        for index in 0..<600 {
            let turn = CopilotTurn(
                id: UUID(),
                source: index.isMultiple(of: 4) ? .mic : .system,
                text: "three-hour-\(index) \(repeated)",
                segmentIDs: [UUID()],
                tStart: Double(index * 18),
                tEnd: Double((index + 1) * 18)
            )
            turns.append(turn)
            await manager.append(turn)

            let cadenceSnapshot = await manager.snapshot()
            if cadenceSnapshot.refreshEligible {
                let summaryContext = try await manager.assembledContext(
                    reserving: RollingSummaryGenerator.requestEnvelopeCharacterCount
                )
                record(summaryContext.characterCount
                    + RollingSummaryGenerator.requestEnvelopeCharacterCount)
                if case .refreshed = try await manager.refresh(using: ConstantM3Summarizer()) {
                    refreshes += 1
                }
            }

            guard (index + 1).isMultiple(of: 6) else { continue }

            let suggestedEnvelope = CopilotGenerator.suggestedAnswerRequestCharacterCount(
                context: "",
                target: target
            )
            let suggested = try await manager.assembledContext(reserving: suggestedEnvelope)
            record(CopilotGenerator.suggestedAnswerRequestCharacterCount(
                context: suggested.renderedText,
                target: target
            ))

            let commitmentEnvelope = CopilotGenerator.commitmentRequestCharacterCount(
                context: "",
                target: target
            )
            let commitment = try await manager.assembledContext(reserving: commitmentEnvelope)
            record(CopilotGenerator.commitmentRequestCharacterCount(
                context: commitment.renderedText,
                target: target
            ))

            let catchUpEnvelope = CopilotGenerator.catchUpRequestCharacterCount(context: "")
            let catchUp = try await manager.assembledContext(reserving: catchUpEnvelope)
            record(CopilotGenerator.catchUpRequestCharacterCount(context: catchUp.renderedText))

            // JSON quoting expands line breaks. Reserve the exact observed
            // envelope, then reassemble once; the second count is the wire
            // message footprint asserted against the hard ceiling.
            let preliminaryQuery = await manager.assembledContext()
            let queryEnvelope = CopilotGenerator.queryRequestCharacterCount(
                context: preliminaryQuery.renderedText,
                question: question
            ) - preliminaryQuery.characterCount
            let query = try await manager.assembledContext(reserving: queryEnvelope)
            record(CopilotGenerator.queryRequestCharacterCount(
                context: query.renderedText,
                question: question
            ))

            record(CopilotClassifier.requestCharacterCount(
                recentTurns: Array(turns.suffix(10)),
                preferredName: "Hoang"
            ))
        }

        let snapshot = await manager.snapshot()
        let final = await manager.assembledContext()
        let report = M3ThreeHourContextReport(
            transcriptTurns: snapshot.allTurns.count,
            transcriptSeconds: snapshot.transcriptSeconds,
            summaryRefreshes: refreshes,
            checkedRequests: checkedRequests,
            maximumRequestCharacters: maximumCharacters,
            hardCharacterLimit: CopilotContextLimits.hardCharacterLimit,
            latestTenRetained: final.verbatimTurns == Array(turns.suffix(10)),
            hardFailures: 0
        )

        try M3Evidence.printJSON("three_hour_context", report)
        #expect(report.transcriptTurns == 600)
        #expect(report.transcriptSeconds == 10_800)
        #expect(report.summaryRefreshes >= 80)
        #expect(report.checkedRequests >= 580)
        #expect(report.maximumRequestCharacters <= report.hardCharacterLimit)
        #expect(report.latestTenRetained)
        #expect(report.hardFailures == 0)
    }
}
