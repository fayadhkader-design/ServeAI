import Foundation

enum SkillLevel: String, Codable, CaseIterable, Identifiable, Sendable {
    case beginner
    case intermediate
    case advanced
    case competitive

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var detail: String {
        switch self {
        case .beginner: "Building a repeatable motion"
        case .intermediate: "Adding pace and placement"
        case .advanced: "Refining sequence and efficiency"
        case .competitive: "Optimizing under match pressure"
        }
    }

}

enum CameraAngle: String, Codable, CaseIterable, Identifiable, Sendable {
    case side
    case rear

    var id: String { rawValue }
    var title: String { self == .side ? "Side view" : "Rear view" }
    var symbol: String { self == .side ? "figure.tennis" : "viewfinder" }
}

enum AnalysisSource: String, Codable, Sendable {
    case vision
    case coreML
    case experimentalCoreML
    case evaluationCoreML
    case researchCapture
    case simulated

    var title: String {
        switch self {
        case .vision: "On-device Vision heuristic"
        case .coreML: "Validated on-device model"
        case .experimentalCoreML: "Experimental on-device model"
        case .evaluationCoreML: "Evaluation candidate · not released"
        case .researchCapture: "Research capture · no coaching"
        case .simulated: "Simulated sample analysis"
        }
    }

    var detail: String {
        switch self {
        case .vision: "Frames and pose observations were processed on this device using transparent heuristics."
        case .coreML: "Frames were processed on this device by a model that passed ServeAI's release gates."
        case .experimentalCoreML: "Research-only pseudo-label model. It failed technique and priority gates and is not validated coaching advice."
        case .evaluationCoreML: "Exact staged model for repeatability and coach comparison. It has not passed ServeAI's accuracy release gates and is not coaching advice."
        case .researchCapture: "A rejected input-quality sample was encoded only for authorized usability labeling. No technique score or coaching advice was generated."
        case .simulated: "Sample values demonstrate the interface and do not describe this video."
        }
    }

    var requiresCautionBanner: Bool {
        switch self {
        case .experimentalCoreML, .evaluationCoreML, .researchCapture, .simulated: true
        case .vision, .coreML: false
        }
    }

    var assuranceTitle: String {
        switch self {
        case .vision: "Heuristic · not coach-validated"
        case .coreML: "Validated release"
        case .experimentalCoreML: "Failed release gates"
        case .evaluationCoreML: "Release gates pending"
        case .researchCapture: "Usability evidence only"
        case .simulated: "Demo values only"
        }
    }

    var assuranceDetail: String {
        switch self {
        case .vision:
            "Video evidence quality describes joint visibility and tracking, not whether heuristic coaching scores are correct."
        case .coreML:
            "The model passed ServeAI's held-out population gates. Video evidence quality still does not guarantee that this individual prediction is correct."
        case .experimentalCoreML:
            "This research model failed technique and coaching-priority gates. Clear video cannot make its coaching output reliable."
        case .evaluationCoreML:
            "This candidate is collecting repeatability and coach-comparison evidence. Its technique and priority output is not released coaching advice."
        case .researchCapture:
            "This sample intentionally failed the ordinary recording gate. It can be labeled usable or unusable for research, but it contains no ServeAI coaching conclusion."
        case .simulated:
            "The values demonstrate the interface and provide no evidence about the selected video or coaching accuracy."
        }
    }
}

enum ConfidenceLevel: String, Codable, CaseIterable, Sendable {
    case low
    case medium
    case high

    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .low: "exclamationmark.triangle.fill"
        case .medium: "circle.lefthalf.filled"
        case .high: "checkmark.seal.fill"
        }
    }
}

enum InsightSeverity: String, Codable, Sendable {
    case strength
    case opportunity
    case priority

    var title: String {
        switch self {
        case .strength: "Strength"
        case .opportunity: "Opportunity"
        case .priority: "Priority"
        }
    }
}

enum ServePhaseKind: Int, Codable, CaseIterable, Identifiable, Sendable {
    case startingStance = 0
    case ballToss
    case loading
    case trophyPosition
    case legDrive
    case racketDrop
    case upwardAcceleration
    case contactPosition
    case pronation
    case landingFollowThrough

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .startingStance: "Starting stance"
        case .ballToss: "Ball toss"
        case .loading: "Loading phase"
        case .trophyPosition: "Trophy position"
        case .legDrive: "Leg drive"
        case .racketDrop: "Racket drop"
        case .upwardAcceleration: "Upward acceleration"
        case .contactPosition: "Contact position"
        case .pronation: "Pronation"
        case .landingFollowThrough: "Landing & follow-through"
        }
    }

    var shortTitle: String {
        switch self {
        case .landingFollowThrough: "Follow-through"
        case .upwardAcceleration: "Acceleration"
        case .contactPosition: "Contact"
        case .trophyPosition: "Trophy"
        default: title
        }
    }
}

enum AnalysisStage: Int, CaseIterable, Identifiable, Sendable {
    case preparing
    case detecting
    case tracking
    case phases
    case technique
    case feedback

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .preparing: "Preparing video"
        case .detecting: "Detecting player"
        case .tracking: "Tracking body movement"
        case .phases: "Identifying serve phases"
        case .technique: "Evaluating technique"
        case .feedback: "Generating coaching feedback"
        }
    }
}
