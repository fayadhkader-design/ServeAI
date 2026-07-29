import CryptoKit
import Foundation
import Security

struct CapturePlanBinding: Codable, Hashable, Sendable {
    let identifier: String
    let version: String
    let sha256: String
}

struct CapturePlanAssignment: Codable, Hashable, Sendable {
    static let currentPlan = CapturePlanBinding(
        identifier: "serveai-target-domain-pilot-v1",
        version: "1.0.0",
        sha256: "a1ee7cda18662aad442e39992ca6b161fa36fc2cd635a2a5f8b0a3a40bc6198a"
    )

    let plan: CapturePlanBinding
    let slotID: String
    let participantPseudonym: String

    static func make(slotID: String, participantPseudonym: String) throws -> CapturePlanAssignment {
        let slot = slotID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let participant = participantPseudonym.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard slot.hasPrefix("slot-"),
              let slotNumber = Int(slot.dropFirst(5)),
              (1...300).contains(slotNumber),
              slot == String(format: "slot-%03d", slotNumber) else {
            throw CoachLabelingTaskError.invalidManifest("capture slot must use slot-001 through slot-300")
        }
        let participantNumber = ((slotNumber - 1) / 5) + 1
        let expectedParticipant = String(format: "participant-%03d", participantNumber)
        guard participant == expectedParticipant else {
            throw CoachLabelingTaskError.invalidManifest(
                "\(slot) belongs to \(expectedParticipant), not \(participant.isEmpty ? "a blank participant" : participant)"
            )
        }
        return CapturePlanAssignment(
            plan: currentPlan,
            slotID: slot,
            participantPseudonym: participant
        )
    }

    var isValid: Bool {
        guard plan == Self.currentPlan,
              let rebuilt = try? Self.make(slotID: slotID, participantPseudonym: participantPseudonym) else {
            return false
        }
        return rebuilt == self
    }

    var slot: CapturePlanSlot? {
        guard isValid else { return nil }
        return CapturePlanSlot(number: Int(slotID.dropFirst(5)) ?? 0)
    }

    func observedMismatches(in analysis: ServeAnalysis) -> [String] {
        guard let slot else { return ["capture-plan assignment is invalid"] }
        var mismatches: [String] = []
        if analysis.cameraAngle != slot.cameraAngle {
            mismatches.append("slot requires \(slot.cameraAngle.title.lowercased()), but the report is \(analysis.cameraAngle.title.lowercased())")
        }
        if analysis.skillLevel != slot.skillLevel {
            mismatches.append("slot requires a \(slot.skillLevel.title.lowercased()) participant, but the report is \(analysis.skillLevel.title.lowercased())")
        }
        if !slot.resolution.matches(analysis.videoMetadata) {
            mismatches.append("slot requires \(slot.resolution.title), but the video is \(analysis.videoMetadata.width)×\(analysis.videoMetadata.height)")
        }
        if !slot.frameRate.matches(analysis.videoMetadata.nominalFrameRate) {
            mismatches.append("slot requires \(slot.frameRate.title), but the video reports \(Int(analysis.videoMetadata.nominalFrameRate.rounded())) fps")
        }
        return mismatches
    }
}

enum CapturePlanResolution: String, Hashable, Sendable {
    case hd720 = "720p"
    case hd1080 = "1080p"
    case ultraHD4K = "4k"

    var title: String { self == .ultraHD4K ? "4K" : rawValue }

    func matches(_ metadata: VideoMetadata) -> Bool {
        let shortEdge = min(metadata.width, metadata.height)
        switch self {
        case .hd720: return (600..<900).contains(shortEdge)
        case .hd1080: return (900..<1_500).contains(shortEdge)
        case .ultraHD4K: return shortEdge >= 1_500
        }
    }
}

enum CapturePlanFrameRate: String, Hashable, Sendable {
    case fps30 = "30fps"
    case fps60 = "60fps"
    case fps120 = "120fps"

    var title: String {
        switch self {
        case .fps30: "30 fps"
        case .fps60: "60 fps"
        case .fps120: "120 fps"
        }
    }

    func matches(_ value: Double) -> Bool {
        guard value.isFinite, value > 0 else { return false }
        switch self {
        case .fps30: return value < 45
        case .fps60: return (45..<90).contains(value)
        case .fps120: return value >= 90
        }
    }
}

struct CapturePlanSlot: Hashable, Sendable {
    let number: Int
    let participantPseudonym: String
    let split: String
    let serveNumber: Int
    let cameraAngle: CameraAngle
    let skillLevel: SkillLevel
    let dominantHand: DominantHand
    let environment: CourtEnvironment
    let lighting: LightingCondition
    let subjectContrast: SubjectContrast
    let resolution: CapturePlanResolution
    let frameRate: CapturePlanFrameRate
    let sourceDeviceModel: String
    let recordingIssueTags: [RecordingIssueTag]

    var slotID: String { String(format: "slot-%03d", number) }
    var assignment: CapturePlanAssignment? {
        try? CapturePlanAssignment.make(slotID: slotID, participantPseudonym: participantPseudonym)
    }
    var isFailureExample: Bool { !recordingIssueTags.isEmpty }

    init?(number: Int) {
        guard (1...300).contains(number) else { return nil }
        let participantNumber = ((number - 1) / 5) + 1
        let serveNumber = ((number - 1) % 5) + 1
        let rotation = number - 1
        let skills: [SkillLevel] = [.beginner, .intermediate, .advanced, .competitive]
        let lighting: [LightingCondition] = [.evenDaylight, .harshSun, .indoorBright, .lowLight]
        let contrast: [SubjectContrast] = [.typical, .high, .typical, .low]
        let resolutions: [CapturePlanResolution] = [.hd1080, .hd720, .hd1080, .ultraHD4K]
        let frameRates: [CapturePlanFrameRate] = [.fps60, .fps30, .fps60, .fps120]
        let deviceModels = ["iPhone-current-A", "iPhone-current-B", "iPhone-older-A", "iPhone-pro-A"]
        let issues: [RecordingIssueTag] = [.poorFraming, .occlusion, .lowLight, .multiplePeople, .motionBlur]

        self.number = number
        participantPseudonym = String(format: "participant-%03d", participantNumber)
        split = participantNumber <= 36 ? "train" : (participantNumber <= 48 ? "validation" : "test")
        self.serveNumber = serveNumber
        cameraAngle = (participantNumber + serveNumber).isMultiple(of: 2) ? .side : .rear
        skillLevel = skills[(participantNumber - 1) % skills.count]
        dominantHand = participantNumber.isMultiple(of: 5) ? .left : .right
        environment = rotation.isMultiple(of: 3) ? .indoor : .outdoor
        self.lighting = lighting[rotation % lighting.count]
        subjectContrast = contrast[rotation % contrast.count]
        resolution = resolutions[rotation % resolutions.count]
        frameRate = frameRates[rotation % frameRates.count]
        sourceDeviceModel = deviceModels[rotation % deviceModels.count]
        recordingIssueTags = number <= 50 ? [issues[rotation % issues.count]] : []
    }
}

struct CoachTaskAnalysisSnapshot: Codable, Hashable, Sendable {
    let id: UUID
    let createdAt: Date
    let overallScore: Int
    let skillLevel: SkillLevel
    let cameraAngle: CameraAngle
    let source: AnalysisSource
    let phaseScores: [PhaseScore]
    let technicalMetrics: [TechnicalMetric]
    let insights: [CoachingInsight]
    let drills: [RecommendedDrill]
    let limitations: [AnalysisLimitation]
    let confidence: AnalysisConfidence
    let videoMetadata: VideoMetadata
    let modelFeatureEvidence: ServeModelFeatureEvidence
    let modelTrace: AnalysisModelTrace?

    init(analysis: ServeAnalysis, evidence: ServeModelFeatureEvidence) {
        id = analysis.id
        createdAt = analysis.createdAt
        overallScore = analysis.overallScore
        skillLevel = analysis.skillLevel
        cameraAngle = analysis.cameraAngle
        source = analysis.source
        phaseScores = analysis.phaseScores
        technicalMetrics = analysis.technicalMetrics
        insights = analysis.insights
        drills = analysis.drills
        limitations = analysis.limitations
        confidence = analysis.confidence
        videoMetadata = analysis.videoMetadata
        modelFeatureEvidence = evidence
        modelTrace = analysis.modelTrace
    }

    func makeAnalysis(videoURL: URL, labelingTask: CoachLabelingTaskManifest) -> ServeAnalysis {
        ServeAnalysis(
            id: id,
            createdAt: createdAt,
            overallScore: overallScore,
            skillLevel: skillLevel,
            cameraAngle: cameraAngle,
            source: source,
            videoURL: videoURL,
            phaseScores: phaseScores,
            technicalMetrics: technicalMetrics,
            insights: insights,
            drills: drills,
            limitations: limitations,
            confidence: confidence,
            videoMetadata: videoMetadata,
            modelFeatureEvidence: modelFeatureEvidence,
            modelTrace: modelTrace,
            coachLabelingTask: labelingTask
        )
    }
}

struct CoachLabelingTaskPayload: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 2

    let schemaVersion: Int
    let taskID: UUID
    let analysisID: UUID
    let createdAt: Date
    let coordinatorPseudonym: String
    let sourceVideoFilename: String
    let sourceVideoSHA256: String
    let capturePlanAssignment: CapturePlanAssignment
    let analysis: CoachTaskAnalysisSnapshot
}

struct CoachLabelingTaskSignature: Codable, Hashable, Sendable {
    let algorithm: String
    let signerKeyID: String
    let publicKeyX963: String
    let signedContentSHA256: String
    let signatureDER: String
}

struct CoachLabelingTaskManifest: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let payload: CoachLabelingTaskPayload
    let signature: CoachLabelingTaskSignature

    var taskID: UUID { payload.taskID }
    var analysisID: UUID { payload.analysisID }
    var coordinatorPseudonym: String { payload.coordinatorPseudonym }
    var signerKeyID: String { signature.signerKeyID }
}

enum CoachLabelingTaskError: LocalizedError, Equatable {
    case missingVideo
    case missingFeatureEvidence
    case incompleteFeatureEvidence
    case simulatedAnalysis
    case sourceFingerprintMismatch
    case invalidCoordinator
    case unsupportedSchema
    case invalidSignature
    case invalidManifest(String)
    case wrongVideo
    case duplicateAnalysis
    case keyUnavailable

    var errorDescription: String? {
        switch self {
        case .missingVideo: "The original serve video is unavailable."
        case .missingFeatureEvidence: "This analysis has no exportable pose evidence."
        case .incompleteFeatureEvidence: "The pose evidence is incomplete and cannot become a labeling task."
        case .simulatedAnalysis: "Simulated reports cannot become research labeling tasks."
        case .sourceFingerprintMismatch: "The report evidence does not match the original video."
        case .invalidCoordinator: "Enter a coordinator pseudonym with at least three characters."
        case .unsupportedSchema: "This coach task uses an unsupported schema."
        case .invalidSignature: "The coach task signature is invalid or the task was changed."
        case .invalidManifest(let detail): "The coach task is invalid: \(detail)"
        case .wrongVideo: "That is not the video bound to this coach task."
        case .duplicateAnalysis: "This coach task is already on this device."
        case .keyUnavailable: "The device signing key is unavailable."
        }
    }
}

enum CoachLabelingTaskCodec {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func canonicalData<T: Encodable>(for value: T) throws -> Data {
        try encoder().encode(value)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum CoachLabelingTaskCrypto {
    static let algorithm = "ECDSA-P256-SHA256"

    private static func validateResearchCapture(
        source: AnalysisSource,
        overallScore: Int,
        phaseScores: [PhaseScore],
        technicalMetrics: [TechnicalMetric],
        insights: [CoachingInsight],
        drills: [RecommendedDrill],
        capturePlanAssignment: CapturePlanAssignment
    ) throws {
        guard source == .researchCapture else { return }
        guard let slot = capturePlanAssignment.slot,
              !slot.recordingIssueTags.isEmpty else {
            throw CoachLabelingTaskError.invalidManifest(
                "research-only captures must be assigned to an intentional failure slot"
            )
        }
        guard overallScore == 0,
              phaseScores.isEmpty,
              technicalMetrics.isEmpty,
              insights.isEmpty,
              drills.isEmpty else {
            throw CoachLabelingTaskError.invalidManifest(
                "research-only captures cannot contain a coaching score, technique metrics, insights, or drills"
            )
        }
    }

    static func makeManifest(
        analysis: ServeAnalysis,
        coordinatorPseudonym: String,
        capturePlanAssignment: CapturePlanAssignment,
        sourceVideoSHA256: String,
        privateKey: P256.Signing.PrivateKey,
        createdAt: Date = .now,
        taskID: UUID = UUID()
    ) throws -> CoachLabelingTaskManifest {
        let coordinator = coordinatorPseudonym.trimmingCharacters(in: .whitespacesAndNewlines)
        guard coordinator.count >= 3 else { throw CoachLabelingTaskError.invalidCoordinator }
        guard capturePlanAssignment.isValid else {
            throw CoachLabelingTaskError.invalidManifest("capture-plan assignment is invalid")
        }
        let captureMismatches = capturePlanAssignment.observedMismatches(in: analysis)
        guard captureMismatches.isEmpty else {
            throw CoachLabelingTaskError.invalidManifest(captureMismatches.joined(separator: "; "))
        }
        guard analysis.source != .simulated else { throw CoachLabelingTaskError.simulatedAnalysis }
        try validateResearchCapture(
            source: analysis.source,
            overallScore: analysis.overallScore,
            phaseScores: analysis.phaseScores,
            technicalMetrics: analysis.technicalMetrics,
            insights: analysis.insights,
            drills: analysis.drills,
            capturePlanAssignment: capturePlanAssignment
        )
        guard let videoURL = analysis.videoURL else { throw CoachLabelingTaskError.missingVideo }
        guard let evidence = analysis.modelFeatureEvidence else { throw CoachLabelingTaskError.missingFeatureEvidence }
        guard evidence.isCompleteForDataset else { throw CoachLabelingTaskError.incompleteFeatureEvidence }
        let normalizedDigest = sourceVideoSHA256.lowercased()
        guard evidence.provenance.videoSHA256 == normalizedDigest else {
            throw CoachLabelingTaskError.sourceFingerprintMismatch
        }

        let snapshot = CoachTaskAnalysisSnapshot(analysis: analysis, evidence: evidence)
        let payload = CoachLabelingTaskPayload(
            schemaVersion: CoachLabelingTaskPayload.currentSchemaVersion,
            taskID: taskID,
            analysisID: analysis.id,
            createdAt: createdAt,
            coordinatorPseudonym: coordinator,
            sourceVideoFilename: videoURL.lastPathComponent,
            sourceVideoSHA256: normalizedDigest,
            capturePlanAssignment: capturePlanAssignment,
            analysis: snapshot
        )
        let content = try CoachLabelingTaskCodec.canonicalData(for: payload)
        let publicKey = privateKey.publicKey.x963Representation
        let signature = try privateKey.signature(for: content)
        return CoachLabelingTaskManifest(
            schemaVersion: CoachLabelingTaskManifest.currentSchemaVersion,
            payload: payload,
            signature: CoachLabelingTaskSignature(
                algorithm: algorithm,
                signerKeyID: CoachLabelingTaskCodec.sha256(publicKey),
                publicKeyX963: publicKey.base64EncodedString(),
                signedContentSHA256: CoachLabelingTaskCodec.sha256(content),
                signatureDER: signature.derRepresentation.base64EncodedString()
            )
        )
    }

    static func verify(_ manifest: CoachLabelingTaskManifest, now: Date = .now) throws {
        guard manifest.schemaVersion == CoachLabelingTaskManifest.currentSchemaVersion,
              manifest.payload.schemaVersion == CoachLabelingTaskPayload.currentSchemaVersion else {
            throw CoachLabelingTaskError.unsupportedSchema
        }
        let payload = manifest.payload
        guard payload.analysisID == payload.analysis.id else {
            throw CoachLabelingTaskError.invalidManifest("analysis identity does not match")
        }
        guard payload.coordinatorPseudonym.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 else {
            throw CoachLabelingTaskError.invalidCoordinator
        }
        guard payload.capturePlanAssignment.isValid else {
            throw CoachLabelingTaskError.invalidManifest("capture-plan assignment is invalid")
        }
        let captureMismatches = payload.capturePlanAssignment.observedMismatches(
            in: payload.analysis.makeAnalysis(
                videoURL: URL(fileURLWithPath: "/verified-task-video"),
                labelingTask: manifest
            )
        )
        guard captureMismatches.isEmpty else {
            throw CoachLabelingTaskError.invalidManifest(captureMismatches.joined(separator: "; "))
        }
        guard payload.createdAt <= now.addingTimeInterval(300) else {
            throw CoachLabelingTaskError.invalidManifest("creation time is in the future")
        }
        guard payload.analysis.source != .simulated else { throw CoachLabelingTaskError.simulatedAnalysis }
        try validateResearchCapture(
            source: payload.analysis.source,
            overallScore: payload.analysis.overallScore,
            phaseScores: payload.analysis.phaseScores,
            technicalMetrics: payload.analysis.technicalMetrics,
            insights: payload.analysis.insights,
            drills: payload.analysis.drills,
            capturePlanAssignment: payload.capturePlanAssignment
        )
        guard payload.analysis.cameraAngle == payload.analysis.modelFeatureEvidence.sequence.cameraAngle else {
            throw CoachLabelingTaskError.invalidManifest("camera angle conflicts with pose evidence")
        }
        guard payload.analysis.modelFeatureEvidence.isCompleteForDataset else {
            throw CoachLabelingTaskError.incompleteFeatureEvidence
        }
        guard payload.sourceVideoSHA256 == payload.analysis.modelFeatureEvidence.provenance.videoSHA256 else {
            throw CoachLabelingTaskError.sourceFingerprintMismatch
        }
        guard manifest.signature.algorithm == algorithm,
              let publicData = Data(base64Encoded: manifest.signature.publicKeyX963),
              let signatureData = Data(base64Encoded: manifest.signature.signatureDER),
              CoachLabelingTaskCodec.sha256(publicData) == manifest.signature.signerKeyID else {
            throw CoachLabelingTaskError.invalidSignature
        }
        let content = try CoachLabelingTaskCodec.canonicalData(for: payload)
        guard CoachLabelingTaskCodec.sha256(content) == manifest.signature.signedContentSHA256,
              let publicKey = try? P256.Signing.PublicKey(x963Representation: publicData),
              let signature = try? P256.Signing.ECDSASignature(derRepresentation: signatureData),
              publicKey.isValidSignature(signature, for: content) else {
            throw CoachLabelingTaskError.invalidSignature
        }
    }
}

struct CoachTaskDeviceKeyStore {
    private let service = "com.serveai.coach-task-signing"
    private let account = "coordinator-p256-v1"

    func loadOrCreate() throws -> P256.Signing.PrivateKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess,
           let data = result as? Data,
           let key = try? P256.Signing.PrivateKey(rawRepresentation: data) {
            return key
        }
        guard status == errSecItemNotFound else { throw CoachLabelingTaskError.keyUnavailable }

        let key = P256.Signing.PrivateKey()
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: key.rawRepresentation
        ]
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else {
            throw CoachLabelingTaskError.keyUnavailable
        }
        return key
    }
}
