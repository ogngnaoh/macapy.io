import Foundation

/// Where calls go and how that endpoint deviates from the OpenAI dialect
/// (SPEC §6.3). One profile is selected at a time; built-ins ship for the four
/// endpoints v1 supports, and users can define their own.
public struct EndpointProfile: Sendable, Equatable, Identifiable {
    public var id: String
    public var displayName: String
    /// The API root, *without* a trailing path component — `/chat/completions`
    /// is appended by the client.
    public var baseURL: URL
    /// Model id for the cheap tier (gates/classifier — SPEC §6.4).
    public var fastModel: String
    /// Model id for the deep tier (generation, artifacts).
    public var deepModel: String
    public var quirks: Quirks
    /// A data-policy note shown in setup UI (SPEC §8: DeepSeek's first-party
    /// endpoint trains on inputs by default and sits outside the EU/US).
    public var dataPolicyNote: String?

    public init(
        id: String,
        displayName: String,
        baseURL: URL,
        fastModel: String,
        deepModel: String,
        quirks: Quirks = Quirks(),
        dataPolicyNote: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.fastModel = fastModel
        self.deepModel = deepModel
        self.quirks = quirks
        self.dataPolicyNote = dataPolicyNote
    }
}

public extension EndpointProfile {
    /// The four endpoints v1 ships with (SPEC §6.3). Model ids are defaults,
    /// not constants — the Providers screen lets the user override both tiers,
    /// which is the escape hatch when a provider rotates model names.
    static let openAI = EndpointProfile(
        id: "openai",
        displayName: "OpenAI",
        baseURL: URL(string: "https://api.openai.com/v1")!,
        fastModel: "gpt-5-nano",
        deepModel: "gpt-5"
    )

    static let openRouter = EndpointProfile(
        id: "openrouter",
        displayName: "OpenRouter",
        baseURL: URL(string: "https://openrouter.ai/api/v1")!,
        fastModel: "openai/gpt-5-nano",
        deepModel: "anthropic/claude-sonnet-4.5",
        dataPolicyNote: "Routes to whichever upstream provider serves the model; each has its own data policy."
    )

    /// The quirkiest profile, and the only one live-verified in M2 (milestone
    /// Integration notes): thinking models require prior `reasoning_content` on
    /// continuations and ignore sampling params while thinking.
    static let deepSeek = EndpointProfile(
        id: "deepseek",
        displayName: "DeepSeek",
        baseURL: URL(string: "https://api.deepseek.com/v1")!,
        fastModel: "deepseek-chat",
        deepModel: "deepseek-reasoner",
        quirks: Quirks(passesBackReasoningContent: true, ignoresSamplingParamsWhenThinking: true),
        dataPolicyNote: "First-party DeepSeek trains on inputs by default and stores data in China (SPEC §8)."
    )

    /// A local model server — the answer to "no bundled inference" (SPEC N3).
    static let ollama = EndpointProfile(
        id: "ollama",
        displayName: "Ollama (local)",
        baseURL: URL(string: "http://localhost:11434/v1")!,
        fastModel: "llama3.2",
        deepModel: "llama3.3",
        quirks: Quirks(requiresAPIKey: false),
        dataPolicyNote: "Runs on this machine; nothing leaves it."
    )

    static let builtIns: [EndpointProfile] = [openAI, openRouter, deepSeek, ollama]
}

/// Per-endpoint deviations from the OpenAI dialect. A descriptor rather than a
/// subclass: every quirk is a flag the one client consults, which is the whole
/// reason v1 ships a single client instead of N provider implementations
/// (SPEC Alt D).
public struct Quirks: Sendable, Equatable {
    /// The endpoint requires an assistant turn's prior `reasoning_content` to
    /// be sent back on continuation requests (DeepSeek thinking models).
    public var passesBackReasoningContent: Bool
    /// The endpoint ignores — and in some versions rejects — sampling
    /// parameters on thinking-mode requests, so they must be omitted.
    public var ignoresSamplingParamsWhenThinking: Bool
    /// The endpoint needs no credentials at all (a local Ollama).
    public var requiresAPIKey: Bool

    public init(
        passesBackReasoningContent: Bool = false,
        ignoresSamplingParamsWhenThinking: Bool = false,
        requiresAPIKey: Bool = true
    ) {
        self.passesBackReasoningContent = passesBackReasoningContent
        self.ignoresSamplingParamsWhenThinking = ignoresSamplingParamsWhenThinking
        self.requiresAPIKey = requiresAPIKey
    }
}
