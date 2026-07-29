import CoreGraphics
import Foundation

struct PhaseScore: Codable, Identifiable, Hashable, Sendable {
    var id: ServePhaseKind { phase }
    let phase: ServePhaseKind
    let score: Int?
    let confidence: ConfidenceLevel
    let note: String

    var displayScore: String { score.map(String.init) ?? "—" }
}

struct JointMeasurement: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let name: String
    let value: Double
    let unit: String
    let frameTime: TimeInterval
    let confidence: Double

    init(id: UUID = UUID(), name: String, value: Double, unit: String, frameTime: TimeInterval, confidence: Double) {
        self.id = id
        self.name = name
        self.value = value
        self.unit = unit
        self.frameTime = frameTime
        self.confidence = confidence
    }
}

struct TechnicalMetric: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let title: String
    let value: String
    let context: String
    let confidence: ConfidenceLevel
    let relatedPhase: ServePhaseKind

    init(id: UUID = UUID(), title: String, value: String, context: String, confidence: ConfidenceLevel, relatedPhase: ServePhaseKind) {
        self.id = id
        self.title = title
        self.value = value
        self.context = context
        self.confidence = confidence
        self.relatedPhase = relatedPhase
    }
}

struct CoachingInsight: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let title: String
    let category: String
    let severity: InsightSeverity
    let observation: String
    let whyItMatters: String
    let correction: String
    let recommendedDrillID: String?
    let confidence: ConfidenceLevel
    let relatedPhase: ServePhaseKind

    init(
        id: UUID = UUID(),
        title: String,
        category: String,
        severity: InsightSeverity,
        observation: String,
        whyItMatters: String,
        correction: String,
        recommendedDrillID: String? = nil,
        confidence: ConfidenceLevel,
        relatedPhase: ServePhaseKind
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.severity = severity
        self.observation = observation
        self.whyItMatters = whyItMatters
        self.correction = correction
        self.recommendedDrillID = recommendedDrillID
        self.confidence = confidence
        self.relatedPhase = relatedPhase
    }
}

struct RecommendedDrill: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let purpose: String
    let instructions: [String]
    let dosage: String
    let difficulty: SkillLevel
    let relatedPhases: [ServePhaseKind]
    let commonMistakes: [String]
    let safetyNote: String?
}

struct AnalysisLimitation: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let title: String
    let detail: String
    let symbol: String

    init(id: UUID = UUID(), title: String, detail: String, symbol: String = "exclamationmark.triangle") {
        self.id = id
        self.title = title
        self.detail = detail
        self.symbol = symbol
    }
}

struct VideoMetadata: Codable, Hashable, Sendable {
    let duration: TimeInterval
    let width: Int
    let height: Int
    let nominalFrameRate: Double
    let usableFrames: Int
    let sampledFrames: Int
}

struct AnalysisConfidence: Codable, Hashable, Sendable {
    let level: ConfidenceLevel
    let visibilityScore: Double
    let poseDetectionQuality: Double
    let cameraSuitability: Double
    let usableFrameCount: Int
    let missingAreas: [String]

    var evidenceScore: Double {
        let weighted = visibilityScore * 0.35
            + poseDetectionQuality * 0.40
            + cameraSuitability * 0.25
        return max(0, min(1, weighted))
    }

    var percentage: Int {
        Int((evidenceScore * 100).rounded())
    }

    var evidenceQualityTitle: String { "\(level.title) video evidence" }
}

struct PosePoint: Codable, Hashable, Sendable {
    let x: Double
    let y: Double
    let confidence: Double

    var point: CGPoint { CGPoint(x: x, y: y) }
}

enum BodyJoint: String, Codable, CaseIterable, Sendable {
    case nose, neck, root
    case leftShoulder, rightShoulder, leftElbow, rightElbow, leftWrist, rightWrist
    case leftHip, rightHip, leftKnee, rightKnee, leftAnkle, rightAnkle
}

struct PoseFrame: Codable, Identifiable, Sendable {
    let id: UUID
    let timestamp: TimeInterval
    let joints: [BodyJoint: PosePoint]
    let bodyConfidence: Double

    init(id: UUID = UUID(), timestamp: TimeInterval, joints: [BodyJoint: PosePoint], bodyConfidence: Double) {
        self.id = id
        self.timestamp = timestamp
        self.joints = joints
        self.bodyConfidence = bodyConfidence
    }
}

struct DetectedServePhase: Codable, Identifiable, Hashable, Sendable {
    var id: ServePhaseKind { phase }
    let phase: ServePhaseKind
    let startTime: TimeInterval
    let endTime: TimeInterval
    let confidence: Double
}

struct AnalysisProgress: Sendable {
    let stage: AnalysisStage
    let fraction: Double
    let detail: String
}
