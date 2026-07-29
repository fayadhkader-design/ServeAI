import Foundation
import SwiftData
import SwiftUI

enum AppRoute: Hashable {
    case pilotCaptureSetup
    case recordingGuide
    case camera(CameraAngle)
    case review(URL, CameraAngle)
    case processing(URL, CameraAngle)
    case report(UUID)
    case frameReview(UUID)
    case coachAnnotation(UUID)
    case importCoachTask
    case history
    case progress
}

@MainActor
final class AppViewModel: ObservableObject {
    @Published var path = NavigationPath()
    @Published private(set) var analyses: [ServeAnalysis] = []
    @Published var presentedError: ServeAIError?
    @Published private(set) var activePilotSlot: CapturePlanSlot?

    let configuration: AppConfiguration
    let analysisService: any ServeAnalysisService
    let recordingQualityAssessor: any RecordingQualityAssessing
    let coachAnnotationStore: any CoachAnnotationPersisting
    private let videoAssetManager: any VideoAssetManaging
    private var repository: (any ServeAnalysisRepository)?

    init(
        configuration: AppConfiguration = .current,
        analysisService: (any ServeAnalysisService)? = nil,
        recordingQualityAssessor: (any RecordingQualityAssessing)? = nil,
        videoAssetManager: (any VideoAssetManaging)? = nil,
        coachAnnotationStore: (any CoachAnnotationPersisting)? = nil
    ) {
        self.configuration = configuration
        self.analysisService = analysisService ?? ServiceFactory.analysisService(configuration: configuration)
        self.videoAssetManager = videoAssetManager ?? LocalVideoAssetManager()
        self.coachAnnotationStore = coachAnnotationStore ?? LocalCoachAnnotationStore()
        if let recordingQualityAssessor {
            self.recordingQualityAssessor = recordingQualityAssessor
        } else {
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-SERVEAI_ACCEPTANCE_PREVIEW") {
                self.recordingQualityAssessor = AcceptancePreviewRecordingQualityAssessor()
            } else if ProcessInfo.processInfo.arguments.contains("-SERVEAI_QUALITY_PREVIEW") {
                self.recordingQualityAssessor = PreviewRecordingQualityAssessor()
            } else {
                self.recordingQualityAssessor = ServiceFactory.recordingQualityAssessor()
            }
#else
            self.recordingQualityAssessor = ServiceFactory.recordingQualityAssessor()
#endif
        }
    }

    func configure(context: ModelContext) {
        guard repository == nil else { return }
        repository = SwiftDataServeAnalysisRepository(context: context)
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-SERVEAI_ACCEPTANCE_PREVIEW") {
            let environment = ProcessInfo.processInfo.environment
            guard configuration.analysisMode == .mock,
                  let videoPath = environment["SERVEAI_ACCEPTANCE_VIDEO"],
                  FileManager.default.fileExists(atPath: videoPath) else {
                presentedError = .recordingFailed(
                    "The Debug acceptance route requires mock analysis and a valid SERVEAI_ACCEPTANCE_VIDEO path."
                )
                return
            }
            do {
                analyses = try repository?.fetchAll() ?? []
            } catch {
                presentedError = .persistenceFailed(error.localizedDescription)
                return
            }
            path.append(AppRoute.review(URL(fileURLWithPath: videoPath), .rear))
            return
        }
        if ProcessInfo.processInfo.arguments.contains("-SERVEAI_TASK_IMPORT_PREVIEW") {
            analyses = MockData.history
            path.append(AppRoute.importCoachTask)
            return
        }
        if ProcessInfo.processInfo.arguments.contains("-SERVEAI_PILOT_PREVIEW") {
            analyses = MockData.history
            path.append(AppRoute.pilotCaptureSetup)
            return
        }
        if ProcessInfo.processInfo.arguments.contains("-SERVEAI_COACH_PREVIEW") {
            let preview = MockData.analysis()
            analyses = [preview]
            path.append(AppRoute.coachAnnotation(preview.id))
            return
        }
        if ProcessInfo.processInfo.arguments.contains("-SERVEAI_QUALITY_PREVIEW") {
            analyses = MockData.history
            path.append(AppRoute.review(URL(fileURLWithPath: "/tmp/serveai-quality-preview.mov"), .side))
            return
        }
        if ProcessInfo.processInfo.arguments.contains("-SERVEAI_SEED_PREVIEW") {
            analyses = MockData.history
            return
        }
        if ProcessInfo.processInfo.arguments.contains("-SERVEAI_HISTORY_PREVIEW") {
            analyses = MockData.history
            path.append(AppRoute.history)
            return
        }
        if ProcessInfo.processInfo.arguments.contains("-SERVEAI_THUMBNAIL_PREVIEW"),
           let videoPath = ProcessInfo.processInfo.environment["SERVEAI_PREVIEW_VIDEO"] {
            let preview = MockData.analysis(videoURL: URL(fileURLWithPath: videoPath))
            analyses = [preview]
            path.append(AppRoute.history)
            Task {
                preview.thumbnailData = await videoAssetManager.thumbnailData(for: URL(fileURLWithPath: videoPath))
            }
            return
        }
#endif
        do {
            analyses = try repository?.fetchAll() ?? []
        } catch {
            presentedError = .persistenceFailed(error.localizedDescription)
            return
        }

        do {
            try videoAssetManager.cleanupOrphanedVideos(referencedURLs: analyses.compactMap(\.videoURL))
        } catch {
            presentedError = .videoDeletionFailed(error.localizedDescription)
        }
        backfillMissingThumbnails()
    }

    func reload() {
        do {
            analyses = try repository?.fetchAll() ?? []
        } catch {
            presentedError = .persistenceFailed(error.localizedDescription)
        }
    }

    func save(_ analysis: ServeAnalysis) {
        do {
            try repository?.save(analysis)
            reload()
        } catch {
            presentedError = .persistenceFailed(error.localizedDescription)
        }
    }

    func delete(_ analysis: ServeAnalysis) {
        let videoURL = analysis.videoURL
        let isLastReference = videoURL.map { target in
            analyses.filter { $0.videoURL?.standardizedFileURL == target.standardizedFileURL }.count <= 1
        } ?? false
        do {
            try repository?.delete(analysis)
            analyses = try repository?.fetchAll() ?? []
        } catch {
            presentedError = .persistenceFailed(error.localizedDescription)
            return
        }

        Task {
            try? await coachAnnotationStore.deleteAll(analysisID: analysis.id)
        }

        guard isLastReference, let videoURL else { return }
        do {
            try videoAssetManager.deleteOwnedVideo(at: videoURL)
        } catch {
            presentedError = .videoDeletionFailed(error.localizedDescription)
        }
    }

    func analysis(id: UUID) -> ServeAnalysis? { analyses.first { $0.id == id } }

    func showGuide() {
        activePilotSlot = nil
        path.append(AppRoute.recordingGuide)
    }
    func showPilotCaptureSetup() { path.append(AppRoute.pilotCaptureSetup) }
    func beginPilotCapture(_ slot: CapturePlanSlot) {
        activePilotSlot = slot
        path.append(AppRoute.recordingGuide)
    }
    func showCamera(angle: CameraAngle) { path.append(AppRoute.camera(angle)) }
    func showReview(url: URL, angle: CameraAngle) { path.append(AppRoute.review(url, angle)) }
    func startAnalysis(url: URL, angle: CameraAngle) { path.append(AppRoute.processing(url, angle)) }
    func showReport(id: UUID) { path.append(AppRoute.report(id)) }
    func showFrameReview(id: UUID) { path.append(AppRoute.frameReview(id)) }
    func showCoachAnnotation(id: UUID) { path.append(AppRoute.coachAnnotation(id)) }
    func showCoachTaskImport() { path.append(AppRoute.importCoachTask) }
    func showHistory() { path.append(AppRoute.history) }
    func showProgress() { path.append(AppRoute.progress) }

    func finishAnalysis(_ analysis: ServeAnalysis) {
        Task {
            if analysis.thumbnailData == nil, let videoURL = analysis.videoURL {
                analysis.thumbnailData = await videoAssetManager.thumbnailData(for: videoURL)
            }
            save(analysis)
            path = NavigationPath()
            path.append(AppRoute.report(analysis.id))
        }
    }

    func finishCoachTaskImport(_ analysis: ServeAnalysis) {
        guard self.analysis(id: analysis.id) == nil else {
            presentedError = .coachTaskImportFailed(CoachLabelingTaskError.duplicateAnalysis.localizedDescription)
            return
        }
        Task {
            if analysis.thumbnailData == nil, let videoURL = analysis.videoURL {
                analysis.thumbnailData = await videoAssetManager.thumbnailData(for: videoURL)
            }
            save(analysis)
            guard self.analysis(id: analysis.id) != nil else { return }
            path = NavigationPath()
            path.append(AppRoute.coachAnnotation(analysis.id))
        }
    }

    private func backfillMissingThumbnails() {
        let candidates = analyses.filter { $0.thumbnailData == nil && $0.videoURL != nil }
        guard !candidates.isEmpty else { return }
        Task {
            var changed = false
            for analysis in candidates {
                guard let videoURL = analysis.videoURL,
                      let data = await videoAssetManager.thumbnailData(for: videoURL) else { continue }
                analysis.thumbnailData = data
                changed = true
            }
            guard changed else { return }
            do {
                try repository?.saveChanges()
                reload()
            } catch {
                presentedError = .persistenceFailed(error.localizedDescription)
            }
        }
    }
}
