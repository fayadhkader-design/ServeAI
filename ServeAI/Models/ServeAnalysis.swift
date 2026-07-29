import Foundation
import SwiftData

struct AnalysisModelTrace: Codable, Hashable, Sendable {
    let modelIdentifier: String
    let modelVersion: String
    let modelArtifactSHA256: String?
    let validatedReleaseVerified: Bool
    let appBuildIdentifier: String
}

@Model
final class ServeAnalysis {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var overallScore: Int
    var skillLevelRaw: String
    var cameraAngleRaw: String
    var sourceRaw: String
    var videoURLString: String?
    var thumbnailData: Data?
    var phaseScoresData: Data
    var technicalMetricsData: Data
    var insightsData: Data
    var drillsData: Data
    var limitationsData: Data
    var confidenceData: Data
    var videoMetadataData: Data
    var modelFeatureEvidenceData: Data?
    var modelTraceData: Data?
    var coachLabelingTaskData: Data?

    init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        overallScore: Int,
        skillLevel: SkillLevel,
        cameraAngle: CameraAngle,
        source: AnalysisSource,
        videoURL: URL?,
        thumbnailData: Data? = nil,
        phaseScores: [PhaseScore],
        technicalMetrics: [TechnicalMetric],
        insights: [CoachingInsight],
        drills: [RecommendedDrill],
        limitations: [AnalysisLimitation],
        confidence: AnalysisConfidence,
        videoMetadata: VideoMetadata,
        modelFeatureEvidence: ServeModelFeatureEvidence? = nil,
        modelTrace: AnalysisModelTrace? = nil,
        coachLabelingTask: CoachLabelingTaskManifest? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.overallScore = max(0, min(100, overallScore))
        self.skillLevelRaw = skillLevel.rawValue
        self.cameraAngleRaw = cameraAngle.rawValue
        self.sourceRaw = source.rawValue
        self.videoURLString = videoURL?.path
        self.thumbnailData = thumbnailData
        self.phaseScoresData = Self.encode(phaseScores)
        self.technicalMetricsData = Self.encode(technicalMetrics)
        self.insightsData = Self.encode(insights)
        self.drillsData = Self.encode(Array(drills.prefix(3)))
        self.limitationsData = Self.encode(limitations)
        self.confidenceData = Self.encode(confidence)
        self.videoMetadataData = Self.encode(videoMetadata)
        self.modelFeatureEvidenceData = modelFeatureEvidence.map(Self.encode)
        self.modelTraceData = modelTrace.map(Self.encode)
        self.coachLabelingTaskData = coachLabelingTask.map(Self.encode)
    }

    var skillLevel: SkillLevel { SkillLevel(rawValue: skillLevelRaw) ?? .intermediate }
    var cameraAngle: CameraAngle { CameraAngle(rawValue: cameraAngleRaw) ?? .side }
    var source: AnalysisSource { AnalysisSource(rawValue: sourceRaw) ?? .simulated }
    var videoURL: URL? { videoURLString.map { URL(fileURLWithPath: $0) } }
    var phaseScores: [PhaseScore] { Self.decode([PhaseScore].self, from: phaseScoresData, fallback: []) }
    var technicalMetrics: [TechnicalMetric] { Self.decode([TechnicalMetric].self, from: technicalMetricsData, fallback: []) }
    var insights: [CoachingInsight] { Self.decode([CoachingInsight].self, from: insightsData, fallback: []) }
    var drills: [RecommendedDrill] { Self.decode([RecommendedDrill].self, from: drillsData, fallback: []) }
    var limitations: [AnalysisLimitation] { Self.decode([AnalysisLimitation].self, from: limitationsData, fallback: []) }
    var confidence: AnalysisConfidence {
        Self.decode(
            AnalysisConfidence.self,
            from: confidenceData,
            fallback: AnalysisConfidence(level: .low, visibilityScore: 0, poseDetectionQuality: 0, cameraSuitability: 0, usableFrameCount: 0, missingAreas: [])
        )
    }
    var videoMetadata: VideoMetadata {
        Self.decode(VideoMetadata.self, from: videoMetadataData, fallback: VideoMetadata(duration: 0, width: 0, height: 0, nominalFrameRate: 0, usableFrames: 0, sampledFrames: 0))
    }
    var modelFeatureEvidence: ServeModelFeatureEvidence? {
        guard let modelFeatureEvidenceData else { return nil }
        return try? JSONDecoder().decode(ServeModelFeatureEvidence.self, from: modelFeatureEvidenceData)
    }
    var modelTrace: AnalysisModelTrace? {
        guard let modelTraceData else { return nil }
        return try? JSONDecoder().decode(AnalysisModelTrace.self, from: modelTraceData)
    }
    var coachLabelingTask: CoachLabelingTaskManifest? {
        guard let coachLabelingTaskData else { return nil }
        return try? JSONDecoder().decode(CoachLabelingTaskManifest.self, from: coachLabelingTaskData)
    }

    var highestScoringPhase: PhaseScore? {
        phaseScores.compactMap { item -> (PhaseScore, Int)? in item.score.map { (item, $0) } }.max { $0.1 < $1.1 }?.0
    }

    var mainImprovement: CoachingInsight? {
        insights.first(where: { $0.severity == .priority }) ?? insights.first(where: { $0.severity == .opportunity })
    }

    private static func encode<T: Encodable>(_ value: T) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data()
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data, fallback: T) -> T {
        (try? JSONDecoder().decode(type, from: data)) ?? fallback
    }
}
