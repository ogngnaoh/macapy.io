import Foundation
import Testing

@testable import AppShell

/// The Spend tab's numerals. An unknown cost must never render as "$0.00" —
/// that is the difference between "this call was free" and "we don't know what
/// this call cost" (slice-02 doc Notes 8).
struct SpendFormatTests {

    @Test func costRendersWithTwoDecimals() {
        #expect(SpendFormat.cost(0.14) == "$0.14")
        #expect(SpendFormat.cost(0) == "$0.00")
    }

    @Test func unknownCostRendersAsADashNotZero() {
        #expect(SpendFormat.cost(nil) == "—")
    }

    @Test func subCentCostsKeepAVisibleMagnitude() {
        // A classifier call can cost $0.0004; showing "$0.00" would read as free.
        #expect(SpendFormat.cost(0.0004) == "<$0.01")
    }

    @Test func tokenCountsAreGrouped() {
        #expect(SpendFormat.tokens(18_204) == "18,204")
        #expect(SpendFormat.tokens(0) == "0")
    }
}
