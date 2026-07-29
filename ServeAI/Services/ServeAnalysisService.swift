import Foundation

protocol ServeAnalysisService: Sendable {
    var source: AnalysisSource { get }
    func analyze(
        videoURL: URL,
        cameraAngle: CameraAngle,
        skillLevel: SkillLevel,
        progress: @escaping @MainActor @Sendable (AnalysisProgress) -> Void
    ) async throws -> ServeAnalysis
}

struct MockServeAnalysisService: ServeAnalysisService {
    let source: AnalysisSource = .simulated

    func analyze(
        videoURL: URL,
        cameraAngle: CameraAngle,
        skillLevel: SkillLevel,
        progress: @escaping @MainActor @Sendable (AnalysisProgress) -> Void
    ) async throws -> ServeAnalysis {
        for (index, stage) in AnalysisStage.allCases.enumerated() {
            try Task.checkCancellation()
            await progress(AnalysisProgress(stage: stage, fraction: Double(index) / Double(AnalysisStage.allCases.count), detail: "Running a clearly labeled interface simulation"))
            try await Task.sleep(for: .milliseconds(420))
        }
        await progress(AnalysisProgress(stage: .feedback, fraction: 1, detail: "Sample report ready"))
        return MockData.analysis(cameraAngle: cameraAngle, skillLevel: skillLevel, videoURL: videoURL)
    }
}
