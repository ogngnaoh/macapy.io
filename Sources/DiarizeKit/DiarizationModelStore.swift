import FluidAudio
import Foundation

/// Where the diarization models live and how they arrive (slice-4 decision 6):
/// presence-gated, consent-gated. `isInstalled` is the availability seam the
/// pipeline consults; `download()` is only ever called behind the explicit
/// Settings consent affordance (the documented G6 exception — author ruling
/// 2026-08-07); `loadInstalled()` can never touch the network by construction
/// (FluidAudio's predownloaded-models loader).
public enum DiarizationModelStore {
    /// FluidAudio's own default cache
    /// (`~/Library/Application Support/FluidAudio/Models/speaker-diarization`)
    /// — shared deliberately: a user who already has the models (another
    /// FluidAudio app, or a manual pre-download) never re-downloads.
    public static var modelsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("speaker-diarization", isDirectory: true)
    }

    static var segmentationModelURL: URL {
        modelsDirectory.appendingPathComponent("pyannote_segmentation.mlmodelc")
    }

    static var embeddingModelURL: URL {
        modelsDirectory.appendingPathComponent("wespeaker_v2.mlmodelc")
    }

    /// Both CoreML bundles present on disk. The one production gate: no
    /// models ⇒ no diarizer ⇒ the meeting runs exactly as M1, zero network.
    public static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: segmentationModelURL.path)
            && FileManager.default.fileExists(atPath: embeddingModelURL.path)
    }

    /// The user-facing size named in the consent prompt.
    public static let approximateDownloadMegabytes = 129

    /// Loads the installed models without any network fallback (FluidAudio's
    /// predownloaded-models path — "No models are downloaded").
    static func loadInstalled() throws -> DiarizerModels {
        try DiarizerModels.load(
            localSegmentationModel: segmentationModelURL,
            localEmbeddingModel: embeddingModelURL
        )
    }

    /// One-time download from Hugging Face into `modelsDirectory`. MUST only
    /// run after the user approved the consent prompt naming endpoint + size.
    public static func download() async throws {
        _ = try await DiarizerModels.downloadIfNeeded()
    }
}
