import Foundation

protocol AnalysisConfidenceCalculating: Sendable {
    func calculate(visibility: Double, poseQuality: Double, usableFrames: Int, expectedFrames: Int, cameraSuitability: Double, missingAreas: [String]) -> AnalysisConfidence
}

struct AnalysisConfidenceCalculator: AnalysisConfidenceCalculating {
    func calculate(
        visibility: Double,
        poseQuality: Double,
        usableFrames: Int,
        expectedFrames: Int,
        cameraSuitability: Double,
        missingAreas: [String]
    ) -> AnalysisConfidence {
        let frameRatio = expectedFrames > 0 ? min(1, Double(usableFrames) / Double(expectedFrames)) : 0
        let boundedVisibility = max(0, min(1, visibility * 0.8 + frameRatio * 0.2))
        let quality = max(0, min(1, poseQuality))
        let suitability = max(0, min(1, cameraSuitability))
        let aggregate = boundedVisibility * 0.35 + quality * 0.40 + suitability * 0.25
        let level: ConfidenceLevel = aggregate >= 0.78 ? .high : (aggregate >= 0.52 ? .medium : .low)
        return AnalysisConfidence(
            level: level,
            visibilityScore: boundedVisibility,
            poseDetectionQuality: quality,
            cameraSuitability: suitability,
            usableFrameCount: usableFrames,
            missingAreas: missingAreas
        )
    }
}
