import Foundation
import Testing

@testable import ProviderKit

/// The shipped price list and the shipped profiles must agree: a built-in
/// profile whose default model has no rate books rows with `estCostUSD == nil`,
/// and unpriced spend never counts toward the per-meeting cap — the cap would
/// be silently blind for that profile out of the box (slice-2 critic pass: the
/// OpenRouter defaults had exactly this hole).
struct PricingDefaultsTests {

    @Test func everyBuiltInProfilesDefaultModelsHaveAShippedRate() {
        for profile in EndpointProfile.builtIns {
            #expect(
                PricingTable.defaults.rates[profile.fastModel] != nil,
                "\(profile.id)'s default fast model \(profile.fastModel) has no shipped rate"
            )
            #expect(
                PricingTable.defaults.rates[profile.deepModel] != nil,
                "\(profile.id)'s default deep model \(profile.deepModel) has no shipped rate"
            )
        }
    }
}
