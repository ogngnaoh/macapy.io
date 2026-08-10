import Foundation
import ProviderKit
import ProviderTestSupport
import Testing

@testable import AgentKit

@Suite(.serialized)
struct M3QualityOracleTests {
    @Test func corpusHasFrozenAuditableShape() throws {
        let corpus = try M3Corpus.load()
        let categories = Dictionary(grouping: corpus, by: \.category).mapValues(\.count)

        #expect(corpus.count == 140)
        #expect(Set(corpus.map(\.id)).count == 140)
        #expect(corpus.count { $0.expected == .none } == 100)
        #expect(corpus.count { $0.expected == .suggestAnswer } == 20)
        #expect(corpus.count { $0.expected == .flagCommitment } == 20)
        #expect(categories == [
            "directed_question": 20,
            "user_commitment": 20,
            "rhetorical_question": 15,
            "third_party_question": 15,
            "undirected_question": 15,
            "suggestion_not_commitment": 15,
            "other_owner_commitment": 15,
            "unowned_commitment": 15,
            "mic_user_speech": 10,
        ])
        #expect(corpus.filter { $0.source == "mic" }.count == 10)
        #expect(corpus.allSatisfy { ["system", "mic"].contains($0.source) })
        #expect(corpus.allSatisfy { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty })
    }

    @Test func deterministicWirePipelineMeetsQuietQualityGuarantee() async throws {
        let corpus = try M3Corpus.load()
        let classified = corpus.filter { $0.audioSource == .system }
        let responses = try classified.map { entry -> FakeOpenAIServer.Response in
            let action = entry.expected.copilotAction
            let decision = try ClassifierDecision(
                action: action,
                confidence: action == nil ? 0.05 : 0.97,
                target: action == nil ? nil : entry.text
            )
            let data = try JSONEncoder().encode(decision)
            return .json(
                status: 200,
                body: OpenAIFixtures.completionBody(
                    content: String(decoding: data, as: UTF8.self),
                    model: EndpointProfile.deepSeek.fastModel,
                    promptTokens: 120,
                    completionTokens: 24
                )
            )
        }
        let server = try FakeOpenAIServer.start(responses: responses)
        defer { server.stop() }

        var profile = EndpointProfile.deepSeek
        profile.baseURL = server.baseURL
        let classifier = CopilotClassifier(
            provider: OpenAICompatibleClient(profile: profile, apiKey: "sk-m3-fixture"),
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

        for entry in corpus {
            let gate = CopilotGate.evaluate(
                turn: entry.turn,
                configuration: configuration,
                state: CopilotGateState(),
                now: now
            )
            switch gate {
            case .allowed:
                let decision = try await classifier.classify(
                    recentTurns: [entry.turn],
                    preferredName: configuration.preferredName
                )
                observations.append(M3ObservedDecision(
                    id: entry.id,
                    expected: entry.expected,
                    observed: M3Evidence.admittedAction(decision)
                ))
            case .rejected(.userSource):
                #expect(entry.audioSource == .mic)
                observations.append(M3ObservedDecision(
                    id: entry.id,
                    expected: entry.expected,
                    observed: nil
                ))
            case .rejected(let reason):
                Issue.record("Unexpected local gate rejection for \(entry.id): \(reason)")
            }
        }

        let score = M3QualityScore.score(observations)
        try M3Evidence.printJSON("fake_quality", score)
        #expect(score.falsePositiveCount == 0)
        #expect(score.questionRecallCount == 20)
        #expect(score.commitmentRecallCount == 20)
        #expect(score.passesQuietGuarantee)
        #expect(server.recordedRequests.count == 130, "mic turns must stop before the network")

        for request in server.recordedRequests {
            let body = try #require(request.jsonBody)
            #expect(body["model"] as? String == "deepseek-v4-flash")
            #expect(body["temperature"] as? Double == 0)
            #expect(body["max_tokens"] as? Int == CopilotClassifier.outputTokenCeiling)
            #expect((body["thinking"] as? [String: String])?["type"] == "disabled")
            #expect((body["response_format"] as? [String: String])?["type"] == "json_object")
        }
    }
}
