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
    /// no cost, while `SpendMeter` conservatively retains the request hold so
    /// the persistent unknown cannot fail an active meeting's cap open.
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
        // Standard Sonnet 5 rates; an introductory $2/$10 runs through
        // 2026-08-31 — the standard rate is kept so the estimate errs high
        // (the cap trips early, never late) and stays right after August.
        "anthropic/claude-sonnet-5": ModelPricing(
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

/// An opaque claim on part of a meeting's cap. Only the meter that issued it
/// can settle or cancel it.
public struct SpendReservation: Sendable, Equatable {
    fileprivate let id: UUID
    public let meetingID: UUID?
    /// The conservative request ceiling held against the cap. `nil` means the
    /// request's model is not in the pricing table, matching ledger rows whose
    /// estimate is intentionally unknown rather than falsely reported as free.
    public let estimatedCostUSD: Double?
}

/// Decides whether an AI call may proceed, reserves its maximum estimated
/// request cost, and books the usage the endpoint actually reports.
///
/// Booked spend plus every in-flight reservation must fit beneath the cap.
/// This removes concurrency-amplified overruns. One call can still cost more
/// than its reservation if the endpoint's tokenizer or accounting exceeds our
/// conservative byte-based estimate; that single-call uncertainty is inherent
/// until the provider reports usage.
public actor SpendMeter {
    private struct ReservationState: Sendable {
        var meetingID: UUID?
        var model: String
        var purpose: Purpose
        var heldCostUSD: Double?
    }

    /// M2 requests did not require `maxTokens`. Keeping them source-compatible
    /// while making M3 reservations bounded requires a safe default; 4,096 is
    /// deliberately above every current M2 structured artifact response.
    static let fallbackMaxTokens = 4_096

    let ledger: any SpendLedger
    public let pricing: PricingTable
    /// `nil` means uncapped (PRD FR-015: the cap is opt-in).
    public private(set) var capUSD: Double?
    private var reservations: [UUID: ReservationState] = [:]
    /// Conservative debits for successful calls whose final cost could not be
    /// represented by the persistent ledger (missing usage, unknown pricing,
    /// or a failed ledger write). They last for this meter's meeting lifetime
    /// so a cap can never fail open merely because accounting was incomplete.
    private var uncertainDebits: [UUID: (meetingID: UUID, costUSD: Double)] = [:]
    private var settlementWaiters: [UUID: CheckedContinuation<Void, any Error>] = [:]

    public init(ledger: any SpendLedger, pricing: PricingTable, capUSD: Double?) {
        self.ledger = ledger
        self.pricing = pricing
        self.capUSD = capUSD
    }

    /// Updates the live cap used by this meter. Existing calls keep their
    /// reservations; subsequent calls immediately observe the new limit.
    public func updateCapUSD(_ capUSD: Double?) {
        self.capUSD = capUSD
    }

    /// Legacy M2 gate retained for source compatibility. New call paths must
    /// use `reserve(_:meetingID:)`, which atomically gates and claims capacity.
    /// This check includes reservations so an older caller cannot ignore M3
    /// in-flight work, but it cannot reserve capacity without a request shape.
    public func authorize(meetingID: UUID?) async throws {
        guard let capUSD, let meetingID else { return }
        let spent = try await ledger.totalCostUSD(meetingID: meetingID)
        let committed = spent
            + uncertainCostUSD(meetingID: meetingID)
            + reservedCostUSD(meetingID: meetingID)
        guard committed < capUSD else {
            throw ProviderError.capReached(spentUSD: committed, capUSD: capUSD)
        }
    }

    /// Atomically gates a call and claims its conservative maximum estimated
    /// cost before the upstream provider can receive a request.
    public func reserve(_ request: CompletionRequest, meetingID: UUID?) async throws -> SpendReservation {
        try Task.checkCancellation()
        let estimate = requestCostCeilingUSD(request)
        var heldCost = estimate
        if let capUSD, let meetingID {
            let spent = try await ledger.totalCostUSD(meetingID: meetingID)
            // Ledger reads are suspension points. Teardown may cancel an
            // admitted call while this read is in flight; never let that stale
            // task create a reservation (and therefore a network request) when
            // it eventually resumes.
            try Task.checkCancellation()
            let committed = spent
                + uncertainCostUSD(meetingID: meetingID)
                + reservedCostUSD(meetingID: meetingID)
            if let estimate {
                guard committed + estimate <= capUSD else {
                    throw ProviderError.capReached(spentUSD: committed, capUSD: capUSD)
                }
            } else {
                // An unpriced custom model cannot produce a trustworthy cost
                // ceiling. Preserve M2 compatibility by permitting one call,
                // but make it claim every remaining dollar so concurrent
                // unpriced calls cannot bypass the cap invariant.
                guard committed < capUSD else {
                    throw ProviderError.capReached(spentUSD: committed, capUSD: capUSD)
                }
                heldCost = capUSD - committed
            }
        }

        try Task.checkCancellation()
        let reservation = SpendReservation(id: UUID(), meetingID: meetingID, estimatedCostUSD: estimate)
        reservations[reservation.id] = ReservationState(
            meetingID: meetingID,
            model: request.model,
            purpose: request.purpose,
            heldCostUSD: heldCost
        )
        return reservation
    }

    /// Settles one reservation using provider-reported usage. The reservation
    /// stays held until the ledger write completes; once actual cost is known,
    /// the held amount is raised to that cost first so concurrent gates cannot
    /// exploit a slow database write.
    @discardableResult
    public func settle(
        _ reservation: SpendReservation,
        usage: TokenUsage?,
        at: Date = Date()
    ) async throws -> SpendEntry? {
        guard var state = reservations[reservation.id] else { return nil }
        guard let usage else {
            finishReservation(reservation.id, state: state, retainingUncertainDebit: true)
            return nil
        }

        let actualCost = pricing.estimatedCostUSD(model: state.model, usage: usage)
        if let actualCost {
            state.heldCostUSD = max(state.heldCostUSD ?? 0, actualCost)
            reservations[reservation.id] = state
        }

        let entry = SpendEntry(
            id: UUID(),
            meetingID: state.meetingID,
            model: state.model,
            usage: usage,
            estCostUSD: actualCost,
            purpose: state.purpose,
            at: at
        )
        do {
            try await ledger.record(entry)
            finishReservation(
                reservation.id,
                state: state,
                retainingUncertainDebit: actualCost == nil
            )
            return entry
        } catch {
            // The provider has completed successfully, so deleting the hold
            // here would make the next request believe the failed write was a
            // free call. Preserve at least the reservation ceiling in memory.
            finishReservation(reservation.id, state: state, retainingUncertainDebit: true)
            throw error
        }
    }

    /// Releases a call that failed or was cancelled before reporting usage.
    public func cancel(_ reservation: SpendReservation) {
        reservations.removeValue(forKey: reservation.id)
        resumeSettlementWaitersIfIdle()
    }

    /// The amount currently held by calls in flight for this meeting.
    public func reservedUSD(meetingID: UUID) -> Double {
        reservedCostUSD(meetingID: meetingID)
    }

    /// Conservative completed-call debits not represented in the ledger.
    /// Exposed for diagnostics and focused invariant tests; callers should use
    /// `spentUSD` for the user-facing persistent estimate.
    public func uncertainUSD(meetingID: UUID) -> Double {
        uncertainCostUSD(meetingID: meetingID)
    }

    /// Suspends until every active reservation has either settled or been
    /// cancelled. Lifecycle owners use this before discarding a meeting meter,
    /// ensuring detached ledger settlement has completed. Cancelling the
    /// waiter throws `CancellationError` without cancelling provider calls or
    /// leaking a continuation.
    public func waitForSettlements() async throws {
        try Task.checkCancellation()
        guard !reservations.isEmpty else { return }

        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if reservations.isEmpty {
                    continuation.resume()
                } else if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    settlementWaiters[waiterID] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelSettlementWaiter(waiterID) }
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

    /// A deliberately conservative estimate: one UTF-8 byte per prompt token
    /// (plus message/request framing) and the request's explicit maximum output
    /// tokens. Schemas count because providers bill their serialized contract
    /// as prompt context. Unknown model pricing remains unknown, just like the
    /// final ledger estimate.
    func requestCostCeilingUSD(_ request: CompletionRequest) -> Double? {
        guard pricing.rates[request.model] != nil else { return nil }
        let messageBytes = request.messages.reduce(into: 0) { count, message in
            count += message.content.utf8.count
            count += message.reasoningContent?.utf8.count ?? 0
            count += message.role.rawValue.utf8.count
            count += 64 // conservative chat-token and JSON overhead per message
        }
        let schemaBytes = (request.responseFormat?.name.utf8.count ?? 0)
            + (request.responseFormat?.schema.data.count ?? 0)
        let promptTokenCeiling = messageBytes + schemaBytes + 256
        let outputTokenCeiling = max(0, request.maxTokens ?? Self.fallbackMaxTokens)
        return pricing.estimatedCostUSD(
            model: request.model,
            usage: TokenUsage(
                promptTokens: promptTokenCeiling,
                cachedTokens: 0,
                completionTokens: outputTokenCeiling
            )
        )
    }

    private func reservedCostUSD(meetingID: UUID) -> Double {
        reservations.values
            .filter { $0.meetingID == meetingID }
            .compactMap(\.heldCostUSD)
            .reduce(0, +)
    }

    private func uncertainCostUSD(meetingID: UUID) -> Double {
        uncertainDebits.values
            .filter { $0.meetingID == meetingID }
            .map(\.costUSD)
            .reduce(0, +)
    }

    private func finishReservation(
        _ id: UUID,
        state: ReservationState,
        retainingUncertainDebit: Bool
    ) {
        reservations.removeValue(forKey: id)
        if retainingUncertainDebit,
           let meetingID = state.meetingID,
           let heldCostUSD = state.heldCostUSD,
           heldCostUSD > 0
        {
            uncertainDebits[id] = (meetingID, heldCostUSD)
        }
        resumeSettlementWaitersIfIdle()
    }

    private func cancelSettlementWaiter(_ id: UUID) {
        settlementWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    private func resumeSettlementWaitersIfIdle() {
        guard reservations.isEmpty else { return }
        let waiters = settlementWaiters.values
        settlementWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
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
                var reservation: SpendReservation?
                do {
                    let held = try await meter.reserve(request, meetingID: meetingID)
                    reservation = held
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
                        if usage != nil {
                            await settleLoggingFailure(held, usage: usage, request: request)
                        } else {
                            // Explicit cancellation/transport failure without
                            // reported usage is not a successful completion and
                            // must release its reservation.
                            await meter.cancel(held)
                        }
                        reservation = nil
                        throw error
                    }
                    // A call that died mid-stream never reported counts, and
                    // inventing zeros would make the ledger lie — `usage == nil`
                    // books nothing.
                    await settleLoggingFailure(held, usage: usage, request: request)
                    reservation = nil
                    if let terminalEvent { continuation.yield(terminalEvent) }
                    continuation.finish()
                } catch {
                    if let reservation { await meter.cancel(reservation) }
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
        let reservation = try await meter.reserve(request, meetingID: meetingID)
        do {
            let result = try await upstream.completeReportingUsage(request, as: type)
            await settleLoggingFailure(reservation, usage: result.usage, request: request)
            return result
        } catch {
            if error is CancellationError {
                // A caller-driven cancellation is the one structured failure
                // that proves the request did not complete. Return its held
                // capacity to the meeting immediately.
                await meter.cancel(reservation)
            } else {
                // Structured transports validate finish reasons and decode
                // before returning `CompletedCall`, so length/content-filter,
                // malformed/schema, and transport failures cannot expose any
                // usage that may have arrived in the response. The provider
                // may still have billed the request. Retain the request's
                // conservative ceiling rather than letting sequential failed
                // calls bypass the cap; do not fabricate a ledger usage row.
                await settleLoggingFailure(reservation, usage: nil, request: request)
            }
            throw error
        }
    }

    /// Books on a task detached from the caller — consumer-driven cancellation
    /// (stopping at `.completed`, dismissing a suggestion, a torn-down view)
    /// must not be able to cancel the ledger write for a call the provider
    /// already billed; GRDB's async accesses honor task cancellation and would
    /// skip the insert. And it **never throws**: the provider billed the call
    /// either way, and destroying the completed result — or leaking a raw
    /// `DatabaseError` through the `LLMProvider` contract — over a
    /// bookkeeping row is the worse trade (fix-review D1: a per-meeting
    /// deletion cascading mid-call, or a full disk, must not eat a finished
    /// artifact). The deliberate cost is a logged under-count in exactly
    /// those rare states; in the deletion case the cascade would have removed
    /// the row anyway.
    private func settleLoggingFailure(
        _ reservation: SpendReservation,
        usage: TokenUsage?,
        request: CompletionRequest
    ) async {
        let meter = meter
        let model = request.model
        let purpose = request.purpose
        do {
            _ = try await Task.detached {
                try await meter.settle(reservation, usage: usage)
            }.value
        } catch {
            ProviderLog.bookingFailed(model: model, purpose: purpose, error: error)
        }
    }
}
