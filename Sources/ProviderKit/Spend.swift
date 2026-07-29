import Foundation

/// One billable call, as it lands in `spend_ledger` (SPEC §6.2). `estCostUSD`
/// is **optional on purpose**: a model with no known price yields `nil` rather
/// than `0`, so an unpriced call shows as "—" in the Spend tab instead of
/// quietly claiming it was free.
public struct SpendEntry: Sendable, Equatable, Identifiable {
    public var id: UUID
    /// `nil` for calls outside a meeting (the settings "test connection").
    public var meetingID: UUID?
    public var model: String
    public var usage: TokenUsage
    public var estCostUSD: Double?
    public var purpose: Purpose
    public var at: Date

    public init(
        id: UUID,
        meetingID: UUID?,
        model: String,
        usage: TokenUsage,
        estCostUSD: Double?,
        purpose: Purpose,
        at: Date
    ) {
        self.id = id
        self.meetingID = meetingID
        self.model = model
        self.usage = usage
        self.estCostUSD = estCostUSD
        self.purpose = purpose
        self.at = at
    }
}

/// Where ledger rows go. PersistKit implements this over GRDB; ProviderKit
/// stays free of a database dependency.
public protocol SpendLedger: Sendable {
    func record(_ entry: SpendEntry) async throws
    func totalCostUSD(meetingID: UUID) async throws -> Double
}

/// Per-million-token prices for one model.
public struct ModelPricing: Sendable, Equatable, Codable {
    public var inputPerMillionUSD: Double
    public var cachedInputPerMillionUSD: Double
    public var outputPerMillionUSD: Double

    public init(inputPerMillionUSD: Double, cachedInputPerMillionUSD: Double, outputPerMillionUSD: Double) {
        self.inputPerMillionUSD = inputPerMillionUSD
        self.cachedInputPerMillionUSD = cachedInputPerMillionUSD
        self.outputPerMillionUSD = outputPerMillionUSD
    }
}

/// Model id → price. Defaults ship for the built-in profiles' default models;
/// the Spend tab labels its numbers as estimates against these rates. Provider
/// price lists change faster than this app ships — a Spend-tab rate editor is
/// backlog; until it exists a stale rate is corrected via
/// `SettingsStore.setPricing` or a new build (FR-015).
public struct PricingTable: Sendable, Equatable, Codable {
    public var rates: [String: ModelPricing]

    public init(rates: [String: ModelPricing]) {
        self.rates = rates
    }

    /// Starting rates for the built-in profiles' default models, in USD per
    /// million tokens. Every built-in profile's default fast/deep model must
    /// have an entry (`PricingDefaultsTests`) — a missing rate books rows with
    /// no cost, and costless rows never count toward the per-meeting cap.
    ///
    /// **These are starting points to confirm against the provider's own
    /// pricing page** (DeepSeek rates checked against api-docs.deepseek.com
    /// 2026-07-29; the rest from their published lists). There is no in-app
    /// editor yet — correcting a stale rate means `SettingsStore.setPricing`
    /// or a new build; a Spend-tab editor is on the backlog. Local models are
    /// the one entry certainly correct: your own machine costs nothing.
    public static let defaults = PricingTable(rates: [
        "deepseek-v4-flash": ModelPricing(
            inputPerMillionUSD: 0.14, cachedInputPerMillionUSD: 0.0028, outputPerMillionUSD: 0.28),
        "deepseek-v4-pro": ModelPricing(
            inputPerMillionUSD: 0.435, cachedInputPerMillionUSD: 0.003625, outputPerMillionUSD: 0.87),
        "gpt-5-nano": ModelPricing(
            inputPerMillionUSD: 0.05, cachedInputPerMillionUSD: 0.005, outputPerMillionUSD: 0.40),
        "gpt-5": ModelPricing(
            inputPerMillionUSD: 1.25, cachedInputPerMillionUSD: 0.125, outputPerMillionUSD: 10.00),
        "openai/gpt-5-nano": ModelPricing(
            inputPerMillionUSD: 0.05, cachedInputPerMillionUSD: 0.005, outputPerMillionUSD: 0.40),
        "anthropic/claude-sonnet-4.5": ModelPricing(
            inputPerMillionUSD: 3.00, cachedInputPerMillionUSD: 0.30, outputPerMillionUSD: 15.00),
        "llama3.2": ModelPricing(
            inputPerMillionUSD: 0, cachedInputPerMillionUSD: 0, outputPerMillionUSD: 0),
        "llama3.3": ModelPricing(
            inputPerMillionUSD: 0, cachedInputPerMillionUSD: 0, outputPerMillionUSD: 0),
    ])

    /// Cost of one call, or `nil` when the model has no known rate.
    /// Cached prompt tokens are a *subset* of `promptTokens` and are billed at
    /// the cached rate — the whole point of SPEC §6.4's append-only prompt.
    public func estimatedCostUSD(model: String, usage: TokenUsage) -> Double? {
        guard let rate = rates[model] else { return nil }
        let freshPromptTokens = max(0, usage.promptTokens - usage.cachedTokens)
        let million = 1_000_000.0
        return Double(freshPromptTokens) / million * rate.inputPerMillionUSD
            + Double(usage.cachedTokens) / million * rate.cachedInputPerMillionUSD
            + Double(usage.completionTokens) / million * rate.outputPerMillionUSD
    }
}

/// Decides whether an AI call may proceed, and books what it cost.
///
/// **The cap's honest guarantee:** `authorize` checks *booked* spend, and a
/// call books only on completion — so N concurrent calls can each pass the gate
/// before any of them books, overshooting the cap by up to N in-flight call
/// costs (one call's overshoot is inherent: cost is unknowable pre-call).
/// Bounding that with in-flight reservations is an M3 design item, deferred
/// until the cascade exists to size it against; nothing in shipping code
/// constructs a capped meter yet (slice-2 critic finding).
public actor SpendMeter {
    let ledger: any SpendLedger
    public let pricing: PricingTable
    /// `nil` means uncapped (PRD FR-015: the cap is opt-in).
    public let capUSD: Double?

    public init(ledger: any SpendLedger, pricing: PricingTable, capUSD: Double?) {
        self.ledger = ledger
        self.pricing = pricing
        self.capUSD = capUSD
    }

    /// Throws `ProviderError.capReached` when this meeting has already spent
    /// its allowance. Consulted *before* a request is built, so a capped call
    /// costs nothing — not even a round trip.
    public func authorize(meetingID: UUID?) async throws {
        guard let capUSD, let meetingID else { return }
        let spent = try await ledger.totalCostUSD(meetingID: meetingID)
        guard spent < capUSD else {
            throw ProviderError.capReached(spentUSD: spent, capUSD: capUSD)
        }
    }

    /// Books one call. Returns the entry written, or `nil` when the endpoint
    /// reported no usage at all (nothing known to bill — see
    /// `MeteredProvider`).
    @discardableResult
    public func book(
        usage: TokenUsage?,
        model: String,
        purpose: Purpose,
        meetingID: UUID?,
        at: Date = Date()
    ) async throws -> SpendEntry? {
        guard let usage else { return nil }
        let entry = SpendEntry(
            id: UUID(),
            meetingID: meetingID,
            model: model,
            usage: usage,
            estCostUSD: pricing.estimatedCostUSD(model: model, usage: usage),
            purpose: purpose,
            at: at
        )
        try await ledger.record(entry)
        return entry
    }

    /// What this meeting has spent so far — the Spend tab's per-meeting number.
    public func spentUSD(meetingID: UUID) async throws -> Double {
        try await ledger.totalCostUSD(meetingID: meetingID)
    }
}

/// Wraps any `LLMProvider` so the cap is checked before every call and a ledger
/// row is written after every billed one.
///
/// A decorator rather than logic inside `OpenAICompatibleClient`: metering is
/// then structural — a caller cannot forget to meter, because the only provider
/// the app hands out is a metered one — and the client stays a pure transport.
public struct MeteredProvider: LLMProvider {
    let upstream: any LLMProvider
    let meter: SpendMeter
    /// `nil` for calls outside a meeting; those are booked but never capped.
    let meetingID: UUID?

    public init(upstream: any LLMProvider, meter: SpendMeter, meetingID: UUID?) {
        self.upstream = upstream
        self.meter = meter
        self.meetingID = meetingID
    }

    public func stream(_ request: CompletionRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await meter.authorize(meetingID: meetingID)
                    var usage: TokenUsage?
                    var terminalEvent: LLMEvent?
                    do {
                        for try await event in upstream.stream(request) {
                            if case .completed(let completion) = event {
                                usage = completion.usage
                                // Held back until the booking is written: the
                                // consumer is contractually free to stop
                                // reading at the terminal event, and the
                                // booking must not race that.
                                terminalEvent = event
                            } else {
                                continuation.yield(event)
                            }
                        }
                    } catch {
                        // The upstream may have delivered its billed usage
                        // before the failure or cancellation reached us; the
                        // original error still wins.
                        try? await bookShielded(usage: usage, request: request)
                        throw error
                    }
                    // A call that died mid-stream never reported counts, and
                    // inventing zeros would make the ledger lie — `usage == nil`
                    // books nothing.
                    try await bookShielded(usage: usage, request: request)
                    if let terminalEvent { continuation.yield(terminalEvent) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func completeReportingUsage<T: Decodable>(
        _ request: CompletionRequest,
        as type: T.Type
    ) async throws -> CompletedCall<T> {
        try await meter.authorize(meetingID: meetingID)
        let result = try await upstream.completeReportingUsage(request, as: type)
        try await bookShielded(usage: result.usage, request: request)
        return result
    }

    /// Books on a task detached from the caller: consumer-driven cancellation
    /// (stopping at `.completed`, dismissing a suggestion, a torn-down view)
    /// must not be able to cancel the ledger write for a call the provider
    /// already billed — GRDB's async accesses honor task cancellation and
    /// would skip the insert, silently under-counting spend against the cap.
    private func bookShielded(usage: TokenUsage?, request: CompletionRequest) async throws {
        guard let usage else { return }
        let meter = meter
        let meetingID = meetingID
        let model = request.model
        let purpose = request.purpose
        try await Task.detached {
            try await meter.book(usage: usage, model: model, purpose: purpose, meetingID: meetingID)
        }.value
    }
}
