import Foundation

struct CoachLabelingTaskService {
    private let videoHasher: any VideoContentHashing
    private let keyStore: CoachTaskDeviceKeyStore

    init(
        videoHasher: any VideoContentHashing = SHA256VideoContentHasher(),
        keyStore: CoachTaskDeviceKeyStore = CoachTaskDeviceKeyStore()
    ) {
        self.videoHasher = videoHasher
        self.keyStore = keyStore
    }

    func createManifest(
        for analysis: ServeAnalysis,
        coordinatorPseudonym: String,
        capturePlanAssignment: CapturePlanAssignment
    ) async throws -> CoachLabelingTaskManifest {
        guard let videoURL = analysis.videoURL,
              FileManager.default.fileExists(atPath: videoURL.path) else {
            throw CoachLabelingTaskError.missingVideo
        }
        let digest = try await videoHasher.sha256(of: videoURL)
        return try CoachLabelingTaskCrypto.makeManifest(
            analysis: analysis,
            coordinatorPseudonym: coordinatorPseudonym,
            capturePlanAssignment: capturePlanAssignment,
            sourceVideoSHA256: digest,
            privateKey: keyStore.loadOrCreate()
        )
    }

    func encode(_ manifest: CoachLabelingTaskManifest, prettyPrinted: Bool = true) throws -> Data {
        let encoder = CoachLabelingTaskCodec.encoder()
        if prettyPrinted {
            encoder.outputFormatting.formUnion([.prettyPrinted])
        }
        return try encoder.encode(manifest)
    }

    func decodeAndVerify(_ data: Data, existingAnalysisIDs: Set<UUID> = []) throws -> CoachLabelingTaskManifest {
        let manifest: CoachLabelingTaskManifest
        do {
            manifest = try CoachLabelingTaskCodec.decoder().decode(CoachLabelingTaskManifest.self, from: data)
        } catch {
            throw CoachLabelingTaskError.invalidManifest("the JSON cannot be decoded")
        }
        try CoachLabelingTaskCrypto.verify(manifest)
        guard !existingAnalysisIDs.contains(manifest.analysisID) else {
            throw CoachLabelingTaskError.duplicateAnalysis
        }
        return manifest
    }

    func importVerifiedVideo(_ sourceURL: URL, for manifest: CoachLabelingTaskManifest) async throws -> ServeAnalysis {
        try CoachLabelingTaskCrypto.verify(manifest)
        let digest = try await videoHasher.sha256(of: sourceURL)
        guard digest == manifest.payload.sourceVideoSHA256 else {
            throw CoachLabelingTaskError.wrongVideo
        }
        let persistedURL = try VideoStorage.persist(sourceURL)
        return manifest.payload.analysis.makeAnalysis(videoURL: persistedURL, labelingTask: manifest)
    }
}
