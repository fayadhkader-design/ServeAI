import SwiftUI

struct ProcessingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let videoURL: URL
    let angle: CameraAngle
    let skillLevel: SkillLevel
    let service: any ServeAnalysisService
    let completion: @MainActor (ServeAnalysis) -> Void
    @StateObject private var viewModel: ProcessingViewModel
    @State private var traceRotation: Double = 0

    init(videoURL: URL, angle: CameraAngle, skillLevel: SkillLevel, service: any ServeAnalysisService, completion: @escaping @MainActor (ServeAnalysis) -> Void) {
        self.videoURL = videoURL
        self.angle = angle
        self.skillLevel = skillLevel
        self.service = service
        self.completion = completion
        _viewModel = StateObject(wrappedValue: ProcessingViewModel(service: service))
    }

    var body: some View {
        ZStack {
            ServeAIBackground(showsSpotlight: true)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    progressSummary
                    stageList
                    provenance

                    if let error = viewModel.error {
                        ErrorBanner(error: error, actionTitle: "Back to review", action: { dismiss() })
                            .padding(.top, 24)
                    }

                    Button("Cancel analysis", role: .cancel) {
                        viewModel.cancel()
                        dismiss()
                    }
                    .font(ServeAITheme.body(.subheadline, size: 14, weight: .semibold))
                    .foregroundStyle(ServeAITheme.mutedInk)
                    .frame(minHeight: 52)
                    .padding(.top, 14)
                }
                .frame(maxWidth: 520, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 34)
                .padding(.bottom, 30)
            }
            .scrollIndicators(.hidden)
        }
        .toolbar(.hidden, for: .navigationBar)
        .task {
            if !reduceMotion {
                withAnimation(.linear(duration: 2.8).repeatForever(autoreverses: false)) {
                    traceRotation = 360
                }
            }
            viewModel.start(videoURL: videoURL, angle: angle, skillLevel: skillLevel, completion: completion)
        }
        .onDisappear { if !viewModel.isFinished { viewModel.cancel() } }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 11) {
            ServeAILogo(compact: true)
            Text("Reading the motion")
                .font(ServeAITheme.display(.largeTitle, size: 37))
                .tracking(-1)
            Text("ServeAI is checking the camera evidence first, then evaluating the phases it can see reliably.")
                .font(ServeAITheme.body(.body, size: 16))
                .foregroundStyle(ServeAITheme.mutedInk)
                .lineSpacing(4)
        }
        .padding(.bottom, 30)
    }

    private var progressSummary: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text(Int(viewModel.fraction * 100), format: .number)
                    .font(ServeAITheme.display(.largeTitle, size: 56))
                    .tracking(-1.4)
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: viewModel.fraction)
                Text("%")
                    .font(ServeAITheme.body(.title3, size: 19, weight: .medium))
                    .foregroundStyle(ServeAITheme.mutedInk)
                Spacer()
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(ServeAITheme.brand)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle().fill(ServeAITheme.separator)
                    Rectangle()
                        .fill(ServeAITheme.brand)
                        .frame(width: max(3, geometry.size.width * viewModel.fraction))
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: viewModel.fraction)
                }
            }
            .frame(height: 2)

            VStack(alignment: .leading, spacing: 5) {
                Text(viewModel.stage.title)
                    .font(ServeAITheme.body(.headline, size: 17, weight: .semibold))
                Text(viewModel.detail)
                    .font(ServeAITheme.body(.subheadline, size: 14))
                    .foregroundStyle(ServeAITheme.mutedInk)
                    .lineSpacing(3)
            }
        }
        .padding(20)
        .background(ServeAITheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            if !reduceMotion {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .trim(from: 0.02, to: 0.18)
                    .stroke(ServeAITheme.brand.opacity(0.72), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .rotationEffect(.degrees(traceRotation))
            } else {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(ServeAITheme.separator)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Analysis progress")
        .accessibilityValue("\(Int(viewModel.fraction * 100)) percent, \(viewModel.stage.title)")
    }

    private var stageList: some View {
        VStack(spacing: 0) {
            ForEach(AnalysisStage.allCases) { stage in
                HStack(spacing: 14) {
                    Image(systemName: statusSymbol(for: stage))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(statusColor(for: stage))
                        .frame(width: 20)
                    Text(stage.title)
                        .font(ServeAITheme.body(.subheadline, size: 15, weight: stage == viewModel.stage ? .semibold : .regular))
                        .foregroundStyle(stage.rawValue <= viewModel.stage.rawValue ? ServeAITheme.ink : ServeAITheme.faintInk)
                    Spacer()
                    if stage == viewModel.stage {
                        Text("In progress")
                            .font(ServeAITheme.body(.caption2, size: 11, weight: .medium))
                            .foregroundStyle(ServeAITheme.brand)
                    }
                }
                .frame(minHeight: 48)
                .overlay(alignment: .bottom) {
                    if stage != AnalysisStage.allCases.last { Rectangle().fill(ServeAITheme.separator).frame(height: 1) }
                }
            }
        }
        .padding(.top, 22)
    }

    private var provenance: some View {
        Label(processingProvenanceLabel, systemImage: processingProvenanceSymbol)
            .font(ServeAITheme.body(.caption, size: 12))
            .foregroundStyle(ServeAITheme.mutedInk)
            .lineSpacing(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 22)
            .accessibilityElement(children: .combine)
    }

    private func statusSymbol(for stage: AnalysisStage) -> String {
        if stage.rawValue < viewModel.stage.rawValue { return "checkmark" }
        if stage == viewModel.stage { return "circle.fill" }
        return "circle"
    }

    private func statusColor(for stage: AnalysisStage) -> Color {
        stage.rawValue <= viewModel.stage.rawValue ? ServeAITheme.brand : ServeAITheme.faintInk
    }

    private var processingProvenanceLabel: String {
        switch service.source {
        case .simulated: "Demo pipeline. Results are labeled simulated."
        case .experimentalCoreML: "Experimental model. Not coach-validated."
        case .evaluationCoreML: "Evaluation only. Not released coaching advice."
        case .researchCapture: "Research capture. No coaching output."
        case .vision, .coreML: "Processed on-device. Your video stays on this iPhone."
        }
    }

    private var processingProvenanceSymbol: String {
        switch service.source {
        case .simulated: "testtube.2"
        case .experimentalCoreML, .evaluationCoreML, .researchCapture: "exclamationmark.triangle.fill"
        case .vision, .coreML: "lock.shield.fill"
        }
    }
}
