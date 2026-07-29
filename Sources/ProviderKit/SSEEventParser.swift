import Foundation

/// Assembles Server-Sent Events from raw bytes, per the SSE spec: lines end at
/// LF, CRLF, or CR — and at nothing else; events end at a blank line; the
/// payload is consecutive `data:` lines joined with a newline.
///
/// Foundation's `AsyncLineSequence` is deliberately **not** used here: it also
/// splits on the Unicode line separators U+0085/U+2028/U+2029, which are legal
/// *unescaped inside JSON strings* (Node's `JSON.stringify` emits them raw), so
/// a delta token carrying one would tear the payload mid-JSON and kill a valid
/// stream (slice-2 critic finding, proven empirically against Foundation).
///
/// Bytes are buffered per line and decoded only when the line is complete, so
/// an event split across TCP deliveries — even mid-way through a multi-byte
/// UTF-8 code point — reassembles correctly. An event left unterminated at
/// end-of-stream is discarded, as the spec requires; the client's
/// protocol-level completion guard is what reports that truncation.
struct SSEEventParser {
    private var lineBytes: [UInt8] = []
    private var dataLines: [String] = []
    private var previousByteWasCR = false
    private var isFirstLine = true

    /// Feeds one byte. Returns a completed event's joined `data:` payload when
    /// a blank line closes the event, else `nil`.
    mutating func consume(_ byte: UInt8) -> String? {
        switch byte {
        case 0x0A: // LF — or the tail of a CRLF whose CR already ended the line
            if previousByteWasCR {
                previousByteWasCR = false
                return nil
            }
            return endOfLine()
        case 0x0D: // CR ends the line; an immediately following LF is swallowed
            previousByteWasCR = true
            return endOfLine()
        default:
            previousByteWasCR = false
            lineBytes.append(byte)
            return nil
        }
    }

    private mutating func endOfLine() -> String? {
        var line = String(decoding: lineBytes, as: UTF8.self)
        lineBytes.removeAll(keepingCapacity: true)

        if isFirstLine {
            isFirstLine = false
            // The spec strips one leading BOM before parsing; without this
            // the first line reads "\u{FEFF}data: …", fails the field match,
            // and the opening event is silently dropped (fix-review D4).
            if line.hasPrefix("\u{FEFF}") { line.removeFirst() }
        }

        if line.isEmpty { // blank line: the event boundary
            guard !dataLines.isEmpty else { return nil }
            let payload = dataLines.joined(separator: "\n")
            dataLines.removeAll(keepingCapacity: true)
            return payload
        }
        if line.hasPrefix(":") { return nil } // comment — the keep-alive several endpoints send
        if line == "data" { // a field without a colon carries an empty value
            dataLines.append("")
        } else if line.hasPrefix("data:") {
            var value = line.dropFirst("data:".count)
            if value.first == " " { value = value.dropFirst() } // spec: one leading space is stripped
            dataLines.append(String(value))
        }
        // `event:`/`id:`/`retry:` fields don't occur in chat-completion streams.
        return nil
    }
}
