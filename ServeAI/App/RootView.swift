import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @AppStorage("didCompleteOnboarding") private var didCompleteOnboarding = false
    @AppStorage("skillLevel") private var skillLevelRaw = SkillLevel.intermediate.rawValue
    @StateObject private var appModel = AppViewModel()

    private var skillLevel: SkillLevel { SkillLevel(rawValue: skillLevelRaw) ?? .intermediate }

    var body: some View {
        Group {
            if didCompleteOnboarding {
                appShell
            } else {
                OnboardingView(selectedSkill: Binding(
                    get: { skillLevel },
                    set: { skillLevelRaw = $0.rawValue }
                )) {
                    didCompleteOnboarding = true
                }
            }
        }
        .tint(ServeAITheme.brand)
        .font(ServeAITheme.body(.body, size: 16))
        .foregroundStyle(ServeAITheme.ink)
        .preferredColorScheme(.dark)
        .task { appModel.configure(context: modelContext) }
        .alert(item: $appModel.presentedError) { error in
            Alert(title: Text(error.errorDescription ?? "ServeAI error"), message: Text(error.recoverySuggestion ?? "Please try again."), dismissButton: .default(Text("OK")))
        }
    }

    private var appShell: some View {
        NavigationStack(path: $appModel.path) {
            MainTabView(appModel: appModel)
                .navigationDestination(for: AppRoute.self) { route in
                    destination(for: route)
                }
        }
        .environmentObject(appModel)
    }

    @ViewBuilder
    private func destination(for route: AppRoute) -> some View {
        switch route {
        case .pilotCaptureSetup:
            PilotCaptureSetupView()
        case .recordingGuide:
            RecordingGuideView()
        case .camera(let angle):
            CameraView(angle: angle)
        case .review(let url, let angle):
            VideoReviewView(videoURL: url, angle: angle)
        case .processing(let url, let angle):
            ProcessingView(
                videoURL: url,
                angle: angle,
                skillLevel: appModel.activePilotSlot?.skillLevel ?? skillLevel,
                service: appModel.analysisService
            ) { result in
                appModel.finishAnalysis(result)
            }
        case .report(let id):
            if let analysis = appModel.analysis(id: id) {
                ServeReportView(
                    analysis: analysis,
                    openFrameReview: { appModel.showFrameReview(id: analysis.id) },
                    openCoachAnnotation: { appModel.showCoachAnnotation(id: analysis.id) }
                )
            } else {
                EmptyStateView(symbol: "doc.text.magnifyingglass", title: "Report unavailable", message: "This analysis may have been deleted.")
            }
        case .frameReview(let id):
            if let analysis = appModel.analysis(id: id) {
                FrameReviewView(analysis: analysis)
            } else {
                EmptyStateView(symbol: "film", title: "Frames unavailable", message: "This analysis may have been deleted.")
            }
        case .coachAnnotation(let id):
            if let analysis = appModel.analysis(id: id) {
                CoachAnnotationView(analysis: analysis, store: appModel.coachAnnotationStore)
            } else {
                EmptyStateView(symbol: "person.text.rectangle", title: "Annotation unavailable", message: "This analysis may have been deleted.")
            }
        case .importCoachTask:
            CoachTaskImportView(
                existingAnalysisIDs: Set(appModel.analyses.map(\.id)),
                onImported: appModel.finishCoachTaskImport
            )
        case .history:
            HistoryView(analyses: appModel.analyses, open: appModel.showReport, delete: appModel.delete)
        case .progress:
            ProgressViewScreen(analyses: appModel.analyses)
        }
    }
}

private struct MainTabView: View {
    @ObservedObject var appModel: AppViewModel

    private var coachingAnalyses: [ServeAnalysis] {
        appModel.analyses.filter { $0.source != .researchCapture }
    }

    var body: some View {
        HomeView(
            analyses: coachingAnalyses,
            analyze: appModel.showGuide,
            open: appModel.showReport,
            showHistory: appModel.showHistory,
            showProgress: appModel.showProgress,
            importCoachTask: appModel.showCoachTaskImport,
            startPilotCapture: appModel.showPilotCaptureSetup
        )
    }
}
