import Foundation

/// Packs rendered transcript lines into chunks no larger than a character
/// budget — the mechanism behind "extraction must not hard-fail at any meeting
/// length" (PRD 3h+ edge case, slice-03 decision 2). Characters, not tokens:
/// the budget is sized with ~4 chars/token of slack, and a tokenizer here
/// would tie AgentKit to one provider's vocabulary.
enum TranscriptChunker {
    /// Greedy packing in order: lines join with newlines until the next line
    /// would cross the budget. A single line longer than the whole budget is
    /// split mid-line into budget-sized windows — degraded extraction beats a
    /// hard failure, and no real utterance is 60k characters.
    static func chunks(_ lines: [String], budgetCharacters: Int) -> [String] {
        precondition(budgetCharacters > 0, "chunk budget must be positive")
        var chunks: [String] = []
        var current = ""

        func flush() {
            if !current.isEmpty {
                chunks.append(current)
                current = ""
            }
        }

        for line in lines {
            if line.count > budgetCharacters {
                flush()
                var remainder = Substring(line)
                while !remainder.isEmpty {
                    chunks.append(String(remainder.prefix(budgetCharacters)))
                    remainder = remainder.dropFirst(budgetCharacters)
                }
                continue
            }
            let joinedCount = current.isEmpty ? line.count : current.count + 1 + line.count
            if joinedCount > budgetCharacters { flush() }
            current = current.isEmpty ? line : current + "\n" + line
        }
        flush()
        return chunks
    }
}
