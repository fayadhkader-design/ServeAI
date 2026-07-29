import Foundation

@MainActor
final class ProcessingViewModel: ObservableObject {
    @Published private(set) var stage: AnalysisStage = .preparing
    @Published private(set) var fraction: Double = 0
    @Published private(set) var detail: String = "Checking the clip"
    @Published private(set) var isFinished = false
    @Published var error: ServeAIError?

    private let service: any ServeAnalysisService
    private var task: Task<Void, Never>?

    init(service: any ServeAnalysisService) {
        self.service = service
    }

    func start(videoURL: URL, angle: CameraAngle, skillLevel: SkillLevel, completion: @escaping @MainActor (ServeAnalysis) -> Void) {
        guard task == nil else { return }
        task = Task {
            do {
                let result = try await service.analyze(videoURL: videoURL, cameraAngle: angle, skillLevel: skillLevel) { [weak self] update in
                    self?.stage = update.stage
                    self?.fraction = update.fraction
                    self?.detail = update.detail
                }
                isFinished = true
                completion(result)
            } catch is CancellationError {
                error = .analysisCanceled
            } catch let known as ServeAIError {
                error = known
            } catch {
                self.error = .poseTrackingFailed
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
