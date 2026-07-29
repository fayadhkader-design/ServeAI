import Foundation

enum RecordingQualityStatus: String, Codable, Sendable {
    case ready
    case warning
    case rejected

    var title: String {
        switch self {
        case .ready: "READY TO ANALYZE"
        case .warning: "USABLE WITH CAUTION"
        case .rejected: "RECORDING NEEDS ATTENTION"
        }
    }
}

enum RecordingQualitySeverity: String, Codable, Sendable {
    case advisory
    case blocking
}

enum RecordingQualityIssueKind: String, Codable, Sendable {
    case duration
    case resolution
    case frameRate
    case playerDetection
    case multiplePeople
    case poseConfidence
    case fullBodyVisibility
    case edgeClipping
}

struct RecordingQualityIssue: Identifiable, Codable, Hashable, Sendable {
    let kind: RecordingQualityIssueKind
    let severity: RecordingQualitySeverity
    let title: String
    let detail: String
    let recovery: String

    var id: String { "\(kind.rawValue)-\(severity.rawValue)" }
}

struct RecordingQualityReport: Codable, Hashable, Sendable {
    let status: RecordingQualityStatus
    let metadata: VideoMetadata
    let poseFrameCount: Int
    let poseCoverage: Double
    let meanPoseConfidence: Double
    let fullBodyCoverage: Double
    let edgeClippingRatio: Double
    let issues: [RecordingQualityIssue]

    var isAcceptable: Bool { status != .rejected }

    init(
        metadata: VideoMetadata,
        poseFrameCount: Int,
        poseCoverage: Double,
        meanPoseConfidence: Double,
        fullBodyCoverage: Double,
        edgeClippingRatio: Double,
        issues: [RecordingQualityIssue]
    ) {
        self.metadata = metadata
        self.poseFrameCount = poseFrameCount
        self.poseCoverage = poseCoverage
        self.meanPoseConfidence = meanPoseConfidence
        self.fullBodyCoverage = fullBodyCoverage
        self.edgeClippingRatio = edgeClippingRatio
        self.issues = issues
        status = issues.contains { $0.severity == .blocking }
            ? .rejected
            : (issues.isEmpty ? .ready : .warning)
    }
}
