import Foundation
import Testing

@testable import AppShell

/// The panel header timer renders elapsed meeting time as HH:MM:SS (design
/// mockups show 00:14:32-style values from minute zero).
struct ElapsedTimeFormatTests {
    @Test func formatsZeroAndSubMinute() {
        #expect(ElapsedTimeFormat.string(seconds: 0) == "00:00:00")
        #expect(ElapsedTimeFormat.string(seconds: 59) == "00:00:59")
    }

    @Test func formatsMinutesAndHours() {
        #expect(ElapsedTimeFormat.string(seconds: 62) == "00:01:02")
        #expect(ElapsedTimeFormat.string(seconds: 3725) == "01:02:05")
    }

    @Test func clampsNegativeToZero() {
        #expect(ElapsedTimeFormat.string(seconds: -5) == "00:00:00")
    }
}
