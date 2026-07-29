import Foundation
import ProviderKit

/// A `SpendLedger` that keeps rows in memory. Shared by ProviderKit's and
/// AppShell's tests; the GRDB-backed `SpendLedgerStore` is exercised against a
/// real database in `PersistKitTests`.
public actor InMemorySpendLedger: SpendLedger {
    public private(set) var entries: [SpendEntry] = []

    public init() {}

    public func record(_ entry: SpendEntry) async throws {
        entries.append(entry)
    }

    public func totalCostUSD(meetingID: UUID) async throws -> Double {
        entries.filter { $0.meetingID == meetingID }.compactMap(\.estCostUSD).reduce(0, +)
    }
}
