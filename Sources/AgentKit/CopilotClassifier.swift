import Foundation
import ProviderKit

/// Fast-tier, non-thinking classifier for proactive moments.
public struct CopilotClassifier: Sendable {
    public static let outputTokenCeiling = 96
    private static let deepSeekSchemaInstructionPrefix =
        "Reply with exactly one JSON object that validates against this JSON Schema "
        + "- no prose, no markdown fences:\n"

    private let provider: any LLMProvider
    public let model: String

    public init(provider: any LLMProvider, model: String) {
        self.provider = provider
        self.model = model
    }

    public func classify(
        recentTurns: [CopilotTurn],
        preferredName: String? = nil
    ) async throws -> ClassifierDecision {
        let turns = Array(recentTurns.suffix(10))
        let requestCharacters = Self.requestCharacterCount(
            recentTurns: turns,
            preferredName: preferredName
        )
        guard requestCharacters <= CopilotContextLimits.hardCharacterLimit else {
            throw CopilotContextError.requestContextExceedsBudget(
                characterCount: requestCharacters
            )
        }
        let request = CompletionRequest(
            model: model,
            messages: [
                .system(Self.systemPrompt(preferredName: preferredName)),
                .user(Self.render(turns)),
            ],
            purpose: .classifier,
            responseFormat: ClassifierDecision.responseFormat,
            temperature: 0,
            maxTokens: Self.outputTokenCeiling,
            thinking: false
        )
        return try await provider.complete(request, as: ClassifierDecision.self)
    }

    /// Conservative exact message-content count for the shipped DeepSeek
    /// endpoint, including its trailing JSON-schema instruction message.
    public static func requestCharacterCount(
        recentTurns: [CopilotTurn],
        preferredName: String? = nil
    ) -> Int {
        systemPrompt(preferredName: preferredName).count
            + render(Array(recentTurns.suffix(10))).count
            + deepSeekSchemaInstructionPrefix.count
            + String(
                decoding: ClassifierDecision.responseFormat.schema.data,
                as: UTF8.self
            ).count
    }

    static func systemPrompt(preferredName: String?) -> String {
        let directedName = preferredName.map {
            "The app user's preferred name is \($0). Treat that name as strong evidence that a question or assignment is directed to them."
        } ?? "The app user's preferred name is unknown; require clear conversational evidence that they are the target."
        return """
            You are a conservative real-time meeting classifier. \(directedName)

            Inspect only the supplied consecutive transcript turns and classify the newest Them turn:
            - suggest_answer: an explicit question directed to the app user that would benefit from an answer.
            - flag_commitment: explicit, concrete work assigned to or accepted by the app user.
            - none: everything else, including rhetorical questions, vague possibilities, third-party work, and acknowledgements.

            Catch-up is never a classifier action. Prefer none when uncertain. The target must be a concise verbatim or normalized description for proactive actions and null for none. Reply only with JSON matching the schema.
            """
    }

    static func render(_ turns: [CopilotTurn]) -> String {
        guard !turns.isEmpty else { return "Transcript has no finalized turns." }
        return "Newest turn is last:\n" + turns.map { turn in
            "\(turn.source == .mic ? "You" : "Them"): \(turn.text)"
        }.joined(separator: "\n")
    }
}
