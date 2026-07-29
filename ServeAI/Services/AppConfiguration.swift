import Foundation

enum AnalysisMode: String, Sendable {
    case mock
    case vision
    case coreML = "coreml"
    case experimentalCoreML = "experimentalcoreml"
    case evaluationCoreML = "evaluationcoreml"
}

struct AppConfiguration: Sendable {
    static let analysisModeEnvironmentKey = "SERVEAI_ANALYSIS_MODE"

    static var permitsEvaluationCandidateMode: Bool {
#if DEBUG
        true
#else
        false
#endif
    }

    static var permitsDevelopmentAnalysisModes: Bool {
#if DEBUG
        true
#else
        false
#endif
    }

    let analysisMode: AnalysisMode

    static var current: AppConfiguration {
        resolve(environment: ProcessInfo.processInfo.environment)
    }

    static func resolve(
        environment: [String: String],
        defaultMode: AnalysisMode = .vision,
        permitsDevelopmentModes: Bool = permitsDevelopmentAnalysisModes
    ) -> AppConfiguration {
        let requestedMode = environment[analysisModeEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let developmentOnlyModes: Set<AnalysisMode> = [.mock, .experimentalCoreML, .evaluationCoreML]
        let normalizedDefaultMode = defaultMode == .evaluationCoreML ? .vision : defaultMode
        let safeDefaultMode = developmentOnlyModes.contains(normalizedDefaultMode)
            && !permitsDevelopmentModes
            ? .vision
            : normalizedDefaultMode
        let requested = requestedMode.flatMap(AnalysisMode.init(rawValue:)) ?? safeDefaultMode
        let resolved = developmentOnlyModes.contains(requested) && !permitsDevelopmentModes
            ? safeDefaultMode
            : requested
        return AppConfiguration(analysisMode: resolved)
    }
}

enum ServiceFactory {
    static func recordingQualityAssessor() -> any RecordingQualityAssessing {
        VisionRecordingQualityAssessor(
            frameExtractor: AVVideoFrameExtractor(),
            poseDetector: VisionBodyPoseDetectionService(),
            evaluator: RecordingQualityEvaluator()
        )
    }

    static func analysisService(configuration: AppConfiguration = .current) -> any ServeAnalysisService {
        switch configuration.analysisMode {
        case .mock:
            MockServeAnalysisService()
        case .vision:
            VisionPoseAnalysisService(
                frameExtractor: AVVideoFrameExtractor(),
                poseDetector: VisionBodyPoseDetectionService(),
                poseTracker: MovingAveragePoseTrackingService(),
                phaseDetector: HeuristicServePhaseDetector(),
                metricsCalculator: ServeMetricsCalculator(),
                confidenceCalculator: AnalysisConfidenceCalculator(),
                feedbackGenerator: ServeFeedbackGenerator()
            )
        case .coreML:
            CoreMLServeAnalysisService(
                frameExtractor: AVVideoFrameExtractor(),
                poseDetector: VisionBodyPoseDetectionService(),
                poseTracker: MovingAveragePoseTrackingService(),
                model: BundledValidatedServeInferenceModel(),
                confidenceCalculator: AnalysisConfidenceCalculator(),
                feedbackGenerator: ServeFeedbackGenerator()
            )
        case .experimentalCoreML:
            CoreMLServeAnalysisService(
                source: .experimentalCoreML,
                frameExtractor: AVVideoFrameExtractor(),
                poseDetector: VisionBodyPoseDetectionService(),
                poseTracker: MovingAveragePoseTrackingService(),
                model: BundledExperimentalServeInferenceModel(),
                confidenceCalculator: AnalysisConfidenceCalculator(),
                feedbackGenerator: ServeFeedbackGenerator()
            )
        case .evaluationCoreML:
#if DEBUG
            CoreMLServeAnalysisService(
                source: .evaluationCoreML,
                frameExtractor: AVVideoFrameExtractor(),
                poseDetector: VisionBodyPoseDetectionService(),
                poseTracker: MovingAveragePoseTrackingService(),
                model: BundledEvaluationCandidateServeInferenceModel(),
                confidenceCalculator: AnalysisConfidenceCalculator(),
                feedbackGenerator: ServeFeedbackGenerator()
            )
#else
            VisionPoseAnalysisService(
                frameExtractor: AVVideoFrameExtractor(),
                poseDetector: VisionBodyPoseDetectionService(),
                poseTracker: MovingAveragePoseTrackingService(),
                phaseDetector: HeuristicServePhaseDetector(),
                metricsCalculator: ServeMetricsCalculator(),
                confidenceCalculator: AnalysisConfidenceCalculator(),
                feedbackGenerator: ServeFeedbackGenerator()
            )
#endif
        }
    }
}
