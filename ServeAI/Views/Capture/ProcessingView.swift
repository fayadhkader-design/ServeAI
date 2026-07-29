import SwiftUI

struct ProcessingView: View {
    @Environment(\.dismiss) private var dismiss
    let videoURL: URL
    let angle: CameraAngle
    let skillLevel: SkillLevel
    let service: any ServeAnalysisService
    let completion: @MainActor (ServeAnalysis) -> Void
    @StateObject private var viewModel: ProcessingViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rotation: Double = 0

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
            ServeAIBackground()
            Circle()
                .fill(ServeAITheme.brand.opacity(0.12))
                .frame(width: 300, height: 300)
                .blur(radius: 28)
                .accessibilityHidden(true)

            ScrollView {
                VStack(spacing: 24) {
                    Spacer(minLength: 82)
                    analysisDial

                    VStack(spacing: 9) {
                        Text(hypeLine)
                            .font(ServeAITheme.display(.title3, size: 21))
                            .foregroundStyle(ServeAITheme.brand)
                            .multilineTextAlignment(.center)
                        Text(viewModel.detail.uppercased())
                            .font(ServeAITheme.mono(.caption, size: 10.5))
                            .tracking(1)
                            .foregroundStyle(ServeAITheme.mutedInk)
                            .multilineTextAlignment(.center)
                    }

                    progressTrack

                    Label(
                        processingProvenanceLabel,
                        systemImage: processingProvenanceSymbol
                    )
                    .font(ServeAITheme.mono(.caption2, size: 9))
                    .tracking(0.5)
                    .foregroundStyle(ServeAITheme.mutedInk)
                    .multilineTextAlignment(.center)

                    if let error = viewModel.error {
                        ErrorBanner(error: error, actionTitle: "Back to review", action: { dismiss() })
                    }

                    Button("CANCEL ANALYSIS", role: .cancel) {
                        viewModel.cancel()
                        dismiss()
                    }
                    .font(ServeAITheme.mono(.caption, size: 10, bold: true))
                    .tracking(0.9)
                    .foregroundStyle(ServeAITheme.mutedInk)
                    .frame(minHeight: 44)
                    Spacer(minLength: 30)
                }
                .frame(maxWidth: 420)
                .padding(.horizontal, 26)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .task {
            if !reduceMotion {
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
            viewModel.start(videoURL: videoURL, angle: angle, skillLevel: skillLevel, completion: completion)
        }
        .onDisappear { if !viewModel.isFinished { viewModel.cancel() } }
    }

    private var processingProvenanceLabel: String {
        switch service.source {
        case .simulated: "DEMO PIPELINE · RESULTS ARE LABELED SIMULATED"
        case .experimentalCoreML: "EXPERIMENTAL MODEL · NOT COACH-VALIDATED"
        case .evaluationCoreML: "EVALUATION ONLY · NOT RELEASED COACHING ADVICE"
        case .researchCapture: "RESEARCH CAPTURE · NO COACHING OUTPUT"
        case .vision, .coreML: "ON-DEVICE · VIDEO STAYS ON THIS IPHONE"
        }
    }

    private var processingProvenanceSymbol: String {
        switch service.source {
        case .simulated: "testtube.2"
        case .experimentalCoreML, .evaluationCoreML, .researchCapture: "exclamationmark.triangle.fill"
        case .vision, .coreML: "lock.shield.fill"
        }
    }

    private var analysisDial: some View {
        ZStack {
            Circle()
                .stroke(ServeAITheme.brand.opacity(0.14), lineWidth: 3)
            Circle()
                .trim(from: 0, to: 0.62)
                .stroke(
                    AngularGradient(colors: [ServeAITheme.brand, ServeAITheme.pink, ServeAITheme.cyan, ServeAITheme.brand], center: .center),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                )
                .rotationEffect(.degrees(rotation - 90))
            Circle()
                .stroke(ServeAITheme.cyan.opacity(0.30), style: StrokeStyle(lineWidth: 2, dash: [5, 7]))
                .padding(16)
                .rotationEffect(.degrees(reduceMotion ? 0 : -rotation * 0.35))
            VStack(spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(Int(viewModel.fraction * 100), format: .number)
                        .font(ServeAITheme.display(.largeTitle, size: 46))
                    Text("%")
                        .font(ServeAITheme.display(.title3, size: 19))
                        .foregroundStyle(ServeAITheme.mutedInk)
                }
                Text("READING FRAMES")
                    .font(ServeAITheme.mono(.caption2, size: 9, bold: true))
                    .tracking(1.3)
                    .foregroundStyle(ServeAITheme.brand)
            }
        }
        .frame(width: 188, height: 188)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Analysis progress")
        .accessibilityValue("\(Int(viewModel.fraction * 100)) percent, \(viewModel.stage.title)")
    }

    private var progressTrack: some View {
        VStack(spacing: 8) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(ServeAITheme.ink.opacity(0.10))
                    Capsule()
                        .fill(LinearGradient(colors: [ServeAITheme.cyan, ServeAITheme.brand, ServeAITheme.pink], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(8, geometry.size.width * viewModel.fraction))
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: viewModel.fraction)
                }
            }
            .frame(height: 8)
            HStack {
                Text("POSE")
                Spacer()
                Text("PHASES")
                Spacer()
                Text("SCORE")
            }
            .font(ServeAITheme.mono(.caption2, size: 9))
            .tracking(0.8)
            .foregroundStyle(ServeAITheme.faintInk)
        }
        .frame(maxWidth: 280)
    }

    private var hypeLine: String {
        switch viewModel.stage {
        case .preparing: "LOADING YOUR TAPE"
        case .detecting: "FINDING THE ATHLETE"
        case .tracking: "READING THE MOTION"
        case .phases: "SEPARATING THE PHASES"
        case .technique: "MEASURING THE MECHANICS"
        case .feedback: "BUILDING YOUR VERDICT"
        }
    }
}
