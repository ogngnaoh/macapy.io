import Foundation
import OSLog

/// ProviderKit's logger (SPEC §5: `os.Logger`, subsystem `io.macapy.app`, one
/// category per module).
///
/// What is deliberately **never** logged here:
/// * key material — SPEC §8 puts keys in the Keychain and nowhere else, and
///   `KeyLeakTests` greps this process's own log entries to keep it that way;
/// * request or response bodies — they carry meeting transcript text, and the
///   log is a file on disk that outlives the meeting (PRD §7: raw content stays
///   in memory unless the user asked for otherwise).
///
/// What is logged is the shape of a call: model, purpose, token counts, and how
/// it ended. That is what a user debugging "why is my provider failing" needs,
/// and it is safe to leave on disk.
enum ProviderLog {
    static let logger = Logger(subsystem: "io.macapy.app", category: "provider")

    static func completed(
        model: String,
        purpose: Purpose,
        streaming: Bool,
        usage: TokenUsage?,
        finishReason: String?
    ) {
        logger.notice(
            """
            llm call completed model=\(model, privacy: .public) \
            purpose=\(purpose.rawValue, privacy: .public) \
            streaming=\(streaming, privacy: .public) \
            promptTokens=\(usage?.promptTokens ?? -1, privacy: .public) \
            cachedTokens=\(usage?.cachedTokens ?? -1, privacy: .public) \
            completionTokens=\(usage?.completionTokens ?? -1, privacy: .public) \
            finish=\(finishReason ?? "none", privacy: .public)
            """
        )
    }

    /// A billed call whose ledger write failed — the one place metering
    /// deliberately swallows an error (the completed result survives; the
    /// ledger under-counts). Logged loudly so the tradeoff stays visible in
    /// diagnostics; only the error's *type* is recorded, never its message.
    static func bookingFailed(model: String, purpose: Purpose, error: Error) {
        logger.error(
            """
            spend booking failed model=\(model, privacy: .public) \
            purpose=\(purpose.rawValue, privacy: .public) \
            error=\(String(describing: type(of: error)), privacy: .public)
            """
        )
    }

    /// Logs the *kind* of failure, not the endpoint's message: a provider is
    /// free to echo request content back in an error string, and that content
    /// is exactly what must not land on disk.
    static func failed(model: String, purpose: Purpose, error: Error) {
        logger.error(
            """
            llm call failed model=\(model, privacy: .public) \
            purpose=\(purpose.rawValue, privacy: .public) \
            error=\(Self.kind(of: error), privacy: .public)
            """
        )
    }

    private static func kind(of error: Error) -> String {
        (error as? ProviderError)?.logDescription ?? "unknown"
    }
}
