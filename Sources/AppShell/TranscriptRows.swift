import Foundation
import PersistKit
import TranscribeKit

/// Pure row-building for the meeting-detail transcript (slice-05 doc decision
/// 5): a `.minuteMark` divider row wherever `floor(tStart / 60)` changes —
/// the mockup's `.tx-time` — so replay reads in minute strides. The same
/// formatter labels search passage rows ("<meeting> · 00:14"), keeping the
/// two surfaces' timestamps identical by construction.
enum TranscriptRows {
    enum Row: Equatable, Identifiable {
        case minuteMark(minute: Int)
        case line(AttributedSegment)

        var id: String {
            switch self {
            case .minuteMark(let minute): "minute-\(minute)"
            case .line(let attributed): attributed.segment.id.uuidString
            }
        }
    }

    /// Segments must arrive ordered by `tStart` (the store guarantees it);
    /// every minute that contains a segment gets one mark, the first minute
    /// included.
    static func build(segments: [AttributedSegment]) -> [Row] {
        var rows: [Row] = []
        var currentMinute = -1
        for attributed in segments {
            let minute = Self.minute(of: attributed.segment.tStart)
            if minute != currentMinute {
                rows.append(.minuteMark(minute: minute))
                currentMinute = minute
            }
            rows.append(.line(attributed))
        }
        return rows
    }

    static func minute(of tStart: TimeInterval) -> Int {
        max(0, Int(tStart / 60))
    }

    /// "00:14" at minute 14, "01:07" past the hour — HH:MM of the minute the
    /// timestamp falls in (check 9 pins the format).
    static func timestampLabel(minute: Int) -> String {
        String(format: "%02d:%02d", minute / 60, minute % 60)
    }

    static func timestampLabel(tStart: TimeInterval) -> String {
        timestampLabel(minute: minute(of: tStart))
    }
}
