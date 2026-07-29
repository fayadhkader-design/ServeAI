import Foundation

enum CoachTechniqueLabel: String, CaseIterable, Sendable {
    case tossPlacement
    case loadingSequence
    case trophyAlignment
    case legDriveTiming
    case contactReach
    case landingBalance

    var title: String {
        switch self {
        case .tossPlacement: "Toss placement"
        case .loadingSequence: "Loading sequence"
        case .trophyAlignment: "Trophy alignment"
        case .legDriveTiming: "Leg-drive timing"
        case .contactReach: "Contact reach"
        case .landingBalance: "Landing balance"
        }
    }
}

extension CoachTechniqueLabel: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        if value == "tossConsistency" {
            self = .tossPlacement
        } else if let label = Self(rawValue: value) {
            self = label
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported coach technique label"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum DominantHand: String, Codable, CaseIterable, Identifiable, Sendable {
    case unknown
    case right
    case left

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum CourtEnvironment: String, Codable, CaseIterable, Identifiable, Sendable {
    case unknown
    case outdoor
    case indoor

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum LightingCondition: String, Codable, CaseIterable, Identifiable, Sendable {
    case unknown
    case evenDaylight
    case harshSun
    case indoorBright
    case lowLight

    var id: String { rawValue }
    var title: String {
        switch self {
        case .unknown: "Unknown"
        case .evenDaylight: "Even daylight"
        case .harshSun: "Harsh sun / shadow"
        case .indoorBright: "Bright indoor"
        case .lowLight: "Low light / night"
        }
    }
}

enum SourceDeviceCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case unknown
    case iPhone
    case otherPhone
    case dedicatedCamera

    var id: String { rawValue }
    var title: String {
        switch self {
        case .unknown: "Unknown"
        case .iPhone: "iPhone"
        case .otherPhone: "Other phone"
        case .dedicatedCamera: "Dedicated camera"
        }
    }
}

enum SubjectContrast: String, Codable, CaseIterable, Identifiable, Sendable {
    case unknown
    case high
    case typical
    case low

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum RecordingIssueTag: String, Codable, CaseIterable, Identifiable, Sendable {
    case poorFraming
    case occlusion
    case lowLight
    case multiplePeople
    case motionBlur

    var id: String { rawValue }
    var title: String {
        switch self {
        case .poorFraming: "Poor framing"
        case .occlusion: "Player occluded"
        case .lowLight: "Low light"
        case .multiplePeople: "Multiple people"
        case .motionBlur: "Motion blur"
        }
    }
}

struct ServeCollectionMetadata: Codable, Hashable, Sendable {
    let dominantHand: DominantHand
    let environment: CourtEnvironment
    let lighting: LightingCondition
    let sourceDeviceCategory: SourceDeviceCategory
    let sourceDeviceModel: String?
    let subjectContrast: SubjectContrast
    let recordingIssueTags: [RecordingIssueTag]
    let videoWidth: Int
    let videoHeight: Int
    let nominalFrameRate: Double

    var isCompleteForDataset: Bool {
        dominantHand != .unknown
            && environment != .unknown
            && lighting != .unknown
            && sourceDeviceCategory != .unknown
            && !(sourceDeviceModel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            && subjectContrast != .unknown
            && videoWidth > 0
            && videoHeight > 0
            && nominalFrameRate > 0
    }
}

struct CoachPhaseBoundaryAnnotation: Codable, Hashable, Sendable {
    let phase: ServePhaseKind
    let startTime: TimeInterval?
    let endTime: TimeInterval?
    let isVisible: Bool

    init(phase: ServePhaseKind, startTime: TimeInterval?, endTime: TimeInterval?, isVisible: Bool) {
        self.phase = phase
        self.startTime = startTime
        self.endTime = endTime
        self.isVisible = isVisible
    }

    private enum CodingKeys: String, CodingKey {
        case phase, startTime, endTime, isVisible
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let identifier = try? container.decode(String.self, forKey: .phase),
           let decodedPhase = Self.phase(forDatasetIdentifier: identifier) {
            phase = decodedPhase
        } else {
            let legacyRawValue = try container.decode(Int.self, forKey: .phase)
            guard let decodedPhase = ServePhaseKind(rawValue: legacyRawValue) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .phase,
                    in: container,
                    debugDescription: "Unsupported serve phase"
                )
            }
            phase = decodedPhase
        }
        startTime = try container.decodeIfPresent(TimeInterval.self, forKey: .startTime)
        endTime = try container.decodeIfPresent(TimeInterval.self, forKey: .endTime)
        isVisible = try container.decode(Bool.self, forKey: .isVisible)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.datasetIdentifier(for: phase), forKey: .phase)
        try container.encodeIfPresent(startTime, forKey: .startTime)
        try container.encodeIfPresent(endTime, forKey: .endTime)
        try container.encode(isVisible, forKey: .isVisible)
    }

    private static func datasetIdentifier(for phase: ServePhaseKind) -> String {
        switch phase {
        case .startingStance: "startingStance"
        case .ballToss: "ballToss"
        case .loading: "loading"
        case .trophyPosition: "trophyPosition"
        case .legDrive: "legDrive"
        case .racketDrop: "racketDrop"
        case .upwardAcceleration: "upwardAcceleration"
        case .contactPosition: "contactPosition"
        case .pronation: "pronation"
        case .landingFollowThrough: "followThrough"
        }
    }

    private static func phase(forDatasetIdentifier identifier: String) -> ServePhaseKind? {
        switch identifier {
        case "startingStance": .startingStance
        case "ballToss": .ballToss
        case "loading": .loading
        case "trophyPosition": .trophyPosition
        case "legDrive": .legDrive
        case "racketDrop": .racketDrop
        case "upwardAcceleration": .upwardAcceleration
        case "contactPosition": .contactPosition
        case "pronation": .pronation
        case "followThrough", "landingFollowThrough": .landingFollowThrough
        default: nil
        }
    }
}

struct CoachTechniqueAnnotation: Codable, Hashable, Sendable {
    let label: CoachTechniqueLabel
    let rating: Int?
    let isVisible: Bool
    let note: String?

    init(label: CoachTechniqueLabel, rating: Int?, isVisible: Bool, note: String? = nil) {
        self.label = label
        self.rating = isVisible ? rating.map { min(5, max(1, $0)) } : nil
        self.isVisible = isVisible
        self.note = note
    }
}

enum DatasetConsentDecisionKind: String, Codable, Sendable {
    case granted
    case revoked
}

struct DatasetConsentDecision: Codable, Hashable, Sendable {
    let id: UUID
    let kind: DatasetConsentDecisionKind
    let occurredAt: Date
    let consentVersion: String
}

struct DatasetConsent: Codable, Hashable, Sendable {
    static let currentVersion = "2026-07"

    let consentVersion: String
    let allowsResearchAndModelTraining: Bool
    let recordedAt: Date?
    let revokedAt: Date?
    let consentRecordID: UUID?
    let decisionHistory: [DatasetConsentDecision]?

    init(
        consentVersion: String,
        allowsResearchAndModelTraining: Bool,
        recordedAt: Date?,
        revokedAt: Date? = nil,
        consentRecordID: UUID? = nil,
        decisionHistory: [DatasetConsentDecision]? = nil
    ) {
        self.consentVersion = consentVersion
        self.allowsResearchAndModelTraining = allowsResearchAndModelTraining
        self.recordedAt = recordedAt
        self.revokedAt = revokedAt
        self.consentRecordID = consentRecordID
        self.decisionHistory = decisionHistory
    }

    var isActive: Bool {
        consentVersion == Self.currentVersion
            && allowsResearchAndModelTraining
            && recordedAt != nil
            && revokedAt == nil
            && consentRecordID != nil
    }

    static func granted(at date: Date = .now, recordID: UUID = UUID()) -> DatasetConsent {
        return DatasetConsent(
            consentVersion: currentVersion,
            allowsResearchAndModelTraining: true,
            recordedAt: date,
            consentRecordID: recordID,
            decisionHistory: [
                DatasetConsentDecision(
                    id: UUID(),
                    kind: .granted,
                    occurredAt: date,
                    consentVersion: currentVersion
                )
            ]
        )
    }

    func revoked(at date: Date = .now) -> DatasetConsent {
        let decision = DatasetConsentDecision(
            id: UUID(),
            kind: .revoked,
            occurredAt: date,
            consentVersion: consentVersion
        )
        return DatasetConsent(
            consentVersion: consentVersion,
            allowsResearchAndModelTraining: false,
            recordedAt: recordedAt,
            revokedAt: date,
            consentRecordID: consentRecordID,
            decisionHistory: (decisionHistory ?? []) + [decision]
        )
    }

    func grantedAgain(at date: Date = .now) -> DatasetConsent {
        let recordID = consentRecordID ?? UUID()
        let decision = DatasetConsentDecision(
            id: UUID(),
            kind: .granted,
            occurredAt: date,
            consentVersion: Self.currentVersion
        )
        return DatasetConsent(
            consentVersion: Self.currentVersion,
            allowsResearchAndModelTraining: true,
            recordedAt: date,
            revokedAt: nil,
            consentRecordID: recordID,
            decisionHistory: (decisionHistory ?? []) + [decision]
        )
    }

    func upgradedForCurrentSchema() -> DatasetConsent {
        guard allowsResearchAndModelTraining,
              let recordedAt,
              revokedAt == nil,
              consentRecordID == nil else { return self }
        return .granted(at: recordedAt)
    }

    static let notGranted = DatasetConsent(
        consentVersion: currentVersion,
        allowsResearchAndModelTraining: false,
        recordedAt: nil
    )
}

struct ModelReportSnapshot: Codable, Hashable, Sendable {
    let source: AnalysisSource
    let overallScore: Int
    let phaseScores: [PhaseScore]
    let confidence: AnalysisConfidence
}

struct CoachServeAnnotationPackage: Codable, Sendable {
    static let currentSchemaVersion = 8

    let schemaVersion: Int
    let rubric: CoachRubricBinding?
    let annotationID: UUID
    let analysisID: UUID
    let createdAt: Date
    let videoFilename: String?
    let cameraAngle: CameraAngle
    let skillLevel: SkillLevel
    let collectionMetadata: ServeCollectionMetadata?
    let modelFeatureEvidence: ServeModelFeatureEvidence?
    let labelingTask: CoachLabelingTaskManifest?
    let participantPseudonym: String?
    let annotatorPseudonym: String?
    let isVideoUsable: Bool
    let unusableReason: String?
    let modelReport: ModelReportSnapshot
    let phaseBoundaries: [CoachPhaseBoundaryAnnotation]
    let techniqueRatings: [CoachTechniqueAnnotation]
    let topPriority: CoachTechniqueLabel?
    let coachNotes: String?
    let consent: DatasetConsent

    static func draft(for analysis: ServeAnalysis) -> CoachServeAnnotationPackage {
        CoachServeAnnotationPackage(
            schemaVersion: currentSchemaVersion,
            rubric: CoachAnnotationRubric.currentBinding,
            annotationID: UUID(),
            analysisID: analysis.id,
            createdAt: .now,
            videoFilename: analysis.videoURL?.lastPathComponent,
            cameraAngle: analysis.cameraAngle,
            skillLevel: analysis.skillLevel,
            collectionMetadata: nil,
            modelFeatureEvidence: analysis.modelFeatureEvidence,
            labelingTask: analysis.coachLabelingTask,
            participantPseudonym: nil,
            annotatorPseudonym: nil,
            isVideoUsable: true,
            unusableReason: nil,
            modelReport: ModelReportSnapshot(
                source: analysis.source,
                overallScore: analysis.overallScore,
                phaseScores: analysis.phaseScores,
                confidence: analysis.confidence
            ),
            phaseBoundaries: [],
            techniqueRatings: [],
            topPriority: nil,
            coachNotes: nil,
            consent: .notGranted
        )
    }
}

struct CoachAnnotationExporter: Sendable {
    func data(for package: CoachServeAnnotationPackage) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(package)
    }

    func temporaryExportURL(for package: CoachServeAnnotationPackage) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("serveai-annotation-\(package.annotationID.uuidString.lowercased())")
            .appendingPathExtension("json")
        try data(for: package).write(to: url, options: .atomic)
        return url
    }
}
