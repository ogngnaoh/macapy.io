import Foundation
import ProviderKit

/// One meeting's transcript → one `MeetingExtraction`, via the deep tier
/// (SPEC §6.4 post-meeting agent). Short transcripts go in a single
/// structured-output call; transcripts over the chunk budget map per-chunk and
/// reduce with a merge call, so no meeting length hard-fails (slice-03
/// decision 2).
public struct PostMeetingExtractor: Sendable {
    /// A complete extraction is bounded even for map/reduce calls. 4,096 is
    /// enough for the 3–5 sentence summary plus a long meeting's explicit
    /// decisions and actions while keeping reservation and spend estimates
    /// finite before the request begins.
    static let maxOutputTokens = 4_096

    let provider: any LLMProvider
    let model: String
    /// Per-call transcript budget in characters (~4 chars/token ⇒ 60k ≈ 15k
    /// tokens — a 1h meeting stays single-pass with wide context margin; the
    /// number is recorded in the slice doc). Injectable down so tests drive
    /// the chunked path without megabyte fixtures.
    let chunkBudgetCharacters: Int

    public init(provider: any LLMProvider, model: String, chunkBudgetCharacters: Int = 60_000) {
        self.provider = provider
        self.model = model
        self.chunkBudgetCharacters = chunkBudgetCharacters
    }

    public func extract(_ transcript: [TranscriptLine]) async throws -> MeetingExtraction {
        let rendered = transcript.map { "\($0.speaker): \($0.text)" }
        let chunks = TranscriptChunker.chunks(rendered, budgetCharacters: chunkBudgetCharacters)

        guard chunks.count > 1 else {
            return try await complete(user: Self.wholeTranscriptPrompt(chunks.first ?? ""))
        }

        // Map concurrently — chunk extractions are independent, and a 3h
        // meeting's wall time should be bounded by the slowest call plus the
        // merge, not their sum (G3). Order is restored by index for the merge.
        let partials = try await withThrowingTaskGroup(
            of: (Int, MeetingExtraction).self
        ) { group in
            for (index, chunk) in chunks.enumerated() {
                group.addTask {
                    (index, try await complete(user: Self.partPrompt(chunk, part: index + 1, of: chunks.count)))
                }
            }
            var collected: [(Int, MeetingExtraction)] = []
            for try await partial in group { collected.append(partial) }
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }

        return try await complete(user: Self.mergePrompt(partials))
    }

    private func complete(user: String) async throws -> MeetingExtraction {
        let request = CompletionRequest(
            model: model,
            messages: [.system(Self.systemPrompt), .user(user)],
            purpose: .artifact,
            responseFormat: MeetingExtraction.responseFormat,
            maxTokens: Self.maxOutputTokens
        )
        return try await provider.complete(request, as: MeetingExtraction.self)
    }

    // MARK: - Prompts

    static let systemPrompt = """
        You are the post-meeting extraction step of a meeting assistant. You receive the \
        transcript of one meeting. Lines starting with "You:" were spoken by the app's user; \
        other speakers are the remaining participants.

        Extract only what the transcript supports:
        - summary: 3-5 plain sentences covering what the meeting was about and where it landed.
        - decisions: each decision the participants explicitly agreed on, one string each.
        - action_items: each task someone actually committed to. For each, set owner and \
        deadline to exactly what was stated in the conversation, or null when none was stated.

        Never invent owners, deadlines, decisions, or facts. Reply with JSON matching the \
        required schema and nothing else.
        """

    static func wholeTranscriptPrompt(_ transcript: String) -> String {
        """
        Transcript:

        \(transcript)

        Extract the summary, decisions, and action items.
        """
    }

    static func partPrompt(_ chunk: String, part: Int, of total: Int) -> String {
        """
        This is part \(part) of \(total) of the transcript; other parts are processed \
        separately.

        \(chunk)

        Extract a summary of this part, plus any decisions and action items that appear in it.
        """
    }

    /// The reduce step. Partials are re-encoded compactly; their combined size
    /// is bounded by extraction output sizes, not transcript length, so the
    /// merge fits one call at any meeting length that terminates.
    static func mergePrompt(_ partials: [MeetingExtraction]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encodedPartials = partials
            .map { partial in
                guard let data = try? encoder.encode(partial) else { return "{}" }
                return String(decoding: data, as: UTF8.self)
            }
            .joined(separator: "\n")
        return """
            These are partial extractions from consecutive parts of one meeting, in order, one \
            JSON object per line:

            \(encodedPartials)

            Merge them into one extraction for the whole meeting: one coherent summary, with \
            decisions and action items deduplicated. Keep owner and deadline values only where \
            a partial states them; never invent new ones.
            """
    }
}
