import Foundation

/// The one LLM surface the rest of the app talks to (SPEC §6.3). A single
/// implementation ships in v1 — `OpenAICompatibleClient` — because every
/// provider macapy supports speaks the OpenAI chat-completions dialect, with
/// differences captured as `Quirks` rather than as separate clients (SPEC N2,
/// Alt D).
public protocol LLMProvider: Sendable {
    /// Streams a completion. Content arrives as `.token`, DeepSeek-style
    /// thinking as `.reasoning`, and the stream ends with exactly one
    /// `.completed` before finishing. Transport and protocol failures surface
    /// as the stream's terminal error, typed as `ProviderError`.
    func stream(_ request: CompletionRequest) -> AsyncThrowingStream<LLMEvent, Error>

    /// One non-streaming call whose response body is decoded as `T`, validated
    /// only once the whole object has arrived (SPEC §6.3: render partial JSON,
    /// validate the final object).
    ///
    /// Returns usage alongside the value — amending SPEC §6.3's `-> T`, because
    /// the spend ledger (FR-015) has to book *every* call, and a decorator that
    /// can't see token counts would have to downcast to the concrete client to
    /// get them.
    func completeReportingUsage<T: Decodable>(
        _ request: CompletionRequest,
        as type: T.Type
    ) async throws -> CompletedCall<T>
}

public extension LLMProvider {
    /// The ergonomic form for callers that don't care about token counts.
    func complete<T: Decodable>(_ request: CompletionRequest, as type: T.Type) async throws -> T {
        try await completeReportingUsage(request, as: type).value
    }
}

/// A decoded structured-output result plus whatever usage the endpoint reported.
public struct CompletedCall<T> {
    public var value: T
    public var usage: TokenUsage?

    public init(value: T, usage: TokenUsage?) {
        self.value = value
        self.usage = usage
    }
}

/// What a call is *for* — carried into the spend ledger so per-meeting cost can
/// be attributed (PRD FR-015, SPEC §6.2 `spend_ledger.purpose`).
public enum Purpose: String, Sendable, Codable, CaseIterable {
    case classifier
    case generation
    case artifact
    case memory
}

/// One chat message. `reasoningContent` exists for DeepSeek's continuation
/// requirement: a thinking model's prior `reasoning_content` must be passed
/// back on the next turn or the continuation is rejected.
public struct ChatMessage: Sendable, Equatable {
    public enum Role: String, Sendable, Codable {
        case system
        case user
        case assistant
    }

    public var role: Role
    public var content: String
    public var reasoningContent: String?

    public init(role: Role, content: String, reasoningContent: String? = nil) {
        self.role = role
        self.content = content
        self.reasoningContent = reasoningContent
    }

    public static func system(_ content: String) -> ChatMessage { .init(role: .system, content: content) }
    public static func user(_ content: String) -> ChatMessage { .init(role: .user, content: content) }
    public static func assistant(_ content: String, reasoningContent: String? = nil) -> ChatMessage {
        .init(role: .assistant, content: content, reasoningContent: reasoningContent)
    }
}

/// A JSON Schema, carried as already-serialized bytes. Serializing at
/// construction (rather than holding `[String: Any]`) is what makes the schema
/// `Sendable` without inventing a JSON value tree — the client parses it back
/// once, when it builds the request body.
public struct JSONSchema: Sendable, Equatable {
    public let data: Data

    /// Serializes a schema written as a plain dictionary literal.
    public init(_ object: [String: Any]) throws {
        data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// The schema as a JSON object, for splicing into a request body.
    func objectValue() throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.malformedResponse("response format schema is not a JSON object")
        }
        return object
    }
}

/// A structured-output contract: the JSON schema the model must fill.
public struct ResponseFormat: Sendable, Equatable {
    public var name: String
    public var schema: JSONSchema

    public init(name: String, schema: JSONSchema) {
        self.name = name
        self.schema = schema
    }
}

/// A request to an OpenAI-compatible endpoint. `model` is explicit rather than
/// "fast/deep" because the caller picks the tier from the profile (SPEC §6.4's
/// cascade decides which tier a given step deserves).
public struct CompletionRequest: Sendable {
    public var model: String
    public var messages: [ChatMessage]
    public var purpose: Purpose
    public var responseFormat: ResponseFormat?
    public var temperature: Double?
    public var maxTokens: Int?
    /// Whether this call is a thinking-mode request (quirks may strip sampling
    /// parameters for these — see `Quirks.ignoresSamplingParamsWhenThinking`).
    public var thinking: Bool

    public init(
        model: String,
        messages: [ChatMessage],
        purpose: Purpose,
        responseFormat: ResponseFormat? = nil,
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        thinking: Bool = false
    ) {
        self.model = model
        self.messages = messages
        self.purpose = purpose
        self.responseFormat = responseFormat
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.thinking = thinking
    }
}

/// One event from a streaming completion.
public enum LLMEvent: Sendable, Equatable {
    /// An answer-content delta — what the user sees.
    case token(String)
    /// A thinking delta (`reasoning_content`). Never shown as answer text; kept
    /// so continuations can pass it back.
    case reasoning(String)
    /// Terminal event, emitted exactly once before the stream finishes.
    case completed(Completion)
}

/// How a completion ended, plus whatever usage the endpoint reported.
public struct Completion: Sendable, Equatable {
    public var finishReason: String?
    public var usage: TokenUsage?

    public init(finishReason: String?, usage: TokenUsage?) {
        self.finishReason = finishReason
        self.usage = usage
    }
}

/// Token counts as reported by the endpoint. `cachedTokens` is the
/// prefix-cache hit count (SPEC §6.4's caching-aware context assembly is only
/// verifiable if we record it); it is a *subset* of `promptTokens`.
public struct TokenUsage: Sendable, Equatable {
    public var promptTokens: Int
    public var cachedTokens: Int
    public var completionTokens: Int

    public init(promptTokens: Int, cachedTokens: Int = 0, completionTokens: Int) {
        self.promptTokens = promptTokens
        self.cachedTokens = cachedTokens
        self.completionTokens = completionTokens
    }
}

/// Every way a provider call can fail, as one typed surface — callers (the
/// copilot cascade, the post-meeting agent) must degrade gracefully rather than
/// guess at `NSError` domains (PRD §7 reliability).
public enum ProviderError: Error, Equatable {
    /// The connection failed or was cut mid-stream.
    case transport(String)
    /// 429 — includes the endpoint's message when it sent one.
    case rateLimited(message: String?)
    /// 5xx.
    case server(status: Int, message: String?)
    /// Any other non-2xx (401 bad key, 400 malformed request, …).
    case http(status: Int, message: String?)
    /// The endpoint reported a failure *inside* an HTTP-200 SSE stream
    /// (`data: {"error": …}`) without a usable status code. OpenRouter-style
    /// proxies do this for upstream failures after streaming has begun; when the
    /// in-band error carries a numeric code, it maps to
    /// `rateLimited`/`server`/`http` instead.
    case inStreamError(message: String?)
    /// The body was not the JSON we expect at all.
    case malformedResponse(String)
    /// A structured-output payload that didn't decode against its schema type.
    case decodingFailed(String)
    /// No credentials for a profile that requires them.
    case missingCredentials(profile: String)
    /// The meeting's spending cap is already spent (PRD FR-015). Refused before
    /// a request is built — and it halts AI only: capture and transcription are
    /// never affected (SPEC §9 kill switches).
    case capReached(spentUSD: Double, capUSD: Double)
}

public extension ProviderError {
    /// One plain sentence naming the cause, for the settings and panel
    /// surfaces. The app's voice is quiet and factual (slice-01 design), and no
    /// user should have to read an enum case to learn their key is wrong.
    var userMessage: String {
        switch self {
        case .transport:
            return "Couldn't reach the provider. Check your connection or the endpoint URL."
        case .rateLimited:
            return "The provider is rate-limiting this key. Try again shortly."
        case .server(let status, _):
            return "The provider had a server error (\(status)). Try again shortly."
        case .http(let status, let message) where status == 401 || status == 403:
            return "The API key was rejected\(message.map { ": \($0)" } ?? ".")"
        case .http(let status, let message):
            return "The provider refused the request (\(status))\(message.map { ": \($0)" } ?? ".")"
        case .inStreamError(let message):
            return "The provider failed mid-reply\(message.map { ": \($0)" } ?? ".")"
        case .malformedResponse:
            return "The endpoint replied in an unexpected format. Check the base URL."
        case .decodingFailed:
            return "The model's reply didn't match the expected format."
        case .missingCredentials:
            return "Add an API key for this provider first."
        case .capReached(let spent, let cap):
            return String(
                format: "This meeting reached its $%.2f cap ($%.2f spent). Capture is unaffected.",
                cap, spent
            )
        }
    }
}
