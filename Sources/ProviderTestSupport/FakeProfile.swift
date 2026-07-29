import Foundation
import ProviderKit

public extension EndpointProfile {
    /// A profile pointed at a `FakeOpenAIServer` instance, with no quirks —
    /// the neutral baseline the built-in profiles are compared against.
    static func fake(baseURL: URL) -> EndpointProfile {
        EndpointProfile(
            id: "fake",
            displayName: "Fake",
            baseURL: baseURL,
            fastModel: "fake-model",
            deepModel: "fake-model",
            quirks: Quirks()
        )
    }
}
