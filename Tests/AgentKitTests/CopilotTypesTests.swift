import CaptureKit
import Foundation
import Testing

@testable import AgentKit

struct CopilotTypesTests {
    private let systemTurn = CopilotTurn(
        source: .system,
        text: "Could you share the migration risks?",
        tStart: 10,
        tEnd: 12
    )

    @Test func strictDecisionDecodesOnlyValidProactiveActions() throws {
        let decoder = JSONDecoder()
        let answer = try decoder.decode(
            ClassifierDecision.self,
            from: Data(#"{"action":"suggest_answer","confidence":0.94,"target":"migration risks"}"#.utf8)
        )
        let expectedAnswer = try ClassifierDecision(
            action: .suggestAnswer,
            confidence: 0.94,
            target: "migration risks"
        )
        #expect(answer == expectedAnswer)

        let none = try decoder.decode(
            ClassifierDecision.self,
            from: Data(#"{"action":"none","confidence":0.15,"target":null}"#.utf8)
        )
        #expect(none.action == nil)
        #expect(none.target == nil)
    }

    @Test(arguments: [
        #"{"action":"catch_up","confidence":0.99,"target":"recent context"}"#,
        #"{"action":"unknown","confidence":0.99,"target":"x"}"#,
        #"{"action":"suggest_answer","confidence":1.1,"target":"x"}"#,
        #"{"action":"suggest_answer","confidence":0.9,"target":null}"#,
        #"{"action":"none","confidence":0.1,"target":"should be null"}"#,
        #"{"action":"none","confidence":0.1}"#,
        #"{"action":"none","confidence":0.1,"target":null,"extra":true}"#,
    ])
    func invalidOrIncompleteDecisionIsRejected(_ json: String) {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ClassifierDecision.self, from: Data(json.utf8))
        }
    }

    @Test func confidenceThresholdIsInclusiveAndClamped() throws {
        let decision = try ClassifierDecision(
            action: .suggestAnswer,
            confidence: 0.90,
            target: "the rollout"
        )
        #expect(decision.meetsThreshold(0.90))
        #expect(!decision.meetsThreshold(0.91))
        #expect(decision.meetsThreshold(-4))
        #expect(!decision.meetsThreshold(4))
        #expect(CopilotConfiguration(confidenceThreshold: 4).confidenceThreshold == 1)
    }

    @Test func deterministicLocalGatesCoverEverySuppression() {
        let now = Date(timeIntervalSince1970: 1_000)
        let enabled = CopilotConfiguration()

        #expect(CopilotGate.evaluate(
            turn: systemTurn, configuration: enabled, state: .init(), now: now) == .allowed)
        #expect(CopilotGate.evaluate(
            turn: systemTurn,
            configuration: .init(aiFeaturesEnabled: false),
            state: .init(),
            now: now) == .rejected(.aiDisabled))
        #expect(CopilotGate.evaluate(
            turn: systemTurn,
            configuration: .init(proactiveEnabled: false),
            state: .init(),
            now: now) == .rejected(.proactiveDisabled))

        var mic = systemTurn
        mic.source = .mic
        #expect(CopilotGate.evaluate(
            turn: mic, configuration: enabled, state: .init(), now: now) == .rejected(.userSource))
        #expect(CopilotGate.evaluate(
            turn: systemTurn,
            configuration: enabled,
            state: .init(userSpeaking: true),
            now: now) == .rejected(.userSpeaking))
        #expect(CopilotGate.evaluate(
            turn: systemTurn,
            configuration: enabled,
            state: .init(hasActiveProactiveCard: true),
            now: now) == .rejected(.activeCard))
        #expect(CopilotGate.evaluate(
            turn: systemTurn,
            configuration: enabled,
            state: .init(lastProactiveAt: now.addingTimeInterval(-44.9)),
            now: now) == .rejected(.cooldown))
        #expect(CopilotGate.evaluate(
            turn: systemTurn,
            configuration: enabled,
            state: .init(lastProactiveAt: now.addingTimeInterval(-45)),
            now: now) == .allowed)

        var filler = systemTurn
        filler.text = "  yeah... "
        #expect(CopilotGate.evaluate(
            turn: filler, configuration: enabled, state: .init(), now: now) == .rejected(.trivialTurn))

        var shortQuestion = systemTurn
        shortQuestion.text = "Why?"
        #expect(CopilotGate.evaluate(
            turn: shortQuestion, configuration: enabled, state: .init(), now: now) == .allowed)
    }
}
