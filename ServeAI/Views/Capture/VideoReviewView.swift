import AVKit
import PhotosUI
import SwiftUI

struct VideoReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appModel: AppViewModel
    let videoURL: URL
    let angle: CameraAngle
    @State private var player: AVPlayer
    @State private var replacementItem: PhotosPickerItem?
    @State private var isPreparing = false
    @State private var isCheckingQuality = true
    @State private var qualityReport: RecordingQualityReport?
    @State private var error: ServeAIError?

    private var clipSelection: VideoClipSelection { .fullClip(videoURL) }

    init(videoURL: URL, angle: CameraAngle) {
        self.videoURL = videoURL
        self.angle = angle
        _player = State(initialValue: AVPlayer(url: videoURL))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                header

                ZStack(alignment: .topLeading) {
                    VideoPlayer(player: player)
                        .aspectRatio(3 / 4, contentMode: .fit)
                        .background(ServeAITheme.deepSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .accessibilityLabel("Serve video preview")
                    Text("FULL CLIP · \(angle.title.uppercased())")
                        .font(ServeAITheme.mono(.caption2, size: 9.5, bold: true))
                        .tracking(0.6)
                        .foregroundStyle(ServeAITheme.brand)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(ServeAITheme.background.opacity(0.82), in: Capsule())
                        .padding(12)
                }
                .overlay { RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(ServeAITheme.separator) }

                HStack {
                    Button {
                        player.seek(to: .zero)
                        player.play()
                    } label: {
                        Label("REPLAY", systemImage: "arrow.counterclockwise")
                    }
                    Spacer()
                    Label("ONE COMPLETE MOTION", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(ServeAITheme.brand)
                }
                .font(ServeAITheme.mono(.caption2, size: 9.5, bold: true))
                .tracking(0.4)
                .frame(minHeight: 44)

                HStack(spacing: 6) {
                    GuideTag(text: angle == .side ? "SIDE ANGLE" : "REAR ANGLE")
                    GuideTag(text: "FULL BODY")
                    GuideTag(text: "FULL CLIP")
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                recordingQualityCard

                if let error {
                    ErrorBanner(error: error, actionTitle: "CHECK AGAIN") {
                        Task { await assessRecordingQuality() }
                    }
                }

                Button { prepareAndAnalyze(clipSelection.sourceURL) } label: {
                    HStack(spacing: 9) {
                        if isPreparing || isCheckingQuality { ProgressView().tint(ServeAITheme.onBrand) }
                        Text(primaryButtonTitle)
                        if !isPreparing, !isCheckingQuality { Image(systemName: "tennisball.fill") }
                    }
                }
                .buttonStyle(ServeAIPrimaryButtonStyle())
                .disabled(isPreparing || isCheckingQuality || qualityReport?.isAcceptable != true)

                if canSaveRejectedPilotSample {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("This slot intentionally targets an input failure. Saving it creates pose evidence for blind usability labeling only—no score, correction, or drill will be generated.")
                            .font(ServeAITheme.body(.caption, size: 12))
                            .foregroundStyle(ServeAITheme.mutedInk)
                        Button {
                            saveRejectedPilotSample()
                        } label: {
                            if isPreparing {
                                HStack { ProgressView(); Text("ENCODING RESEARCH SAMPLE…") }
                            } else {
                                Label("SAVE FAILURE SAMPLE", systemImage: "waveform.path.ecg.rectangle")
                            }
                        }
                        .buttonStyle(ServeAISecondaryButtonStyle())
                        .disabled(isPreparing)
                        .accessibilityHint("Creates research evidence without generating coaching")
                    }
                    .padding(15)
                    .background(ServeAITheme.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(ServeAITheme.orange.opacity(0.30)) }
                }

                HStack(spacing: 9) {
                    Button { dismiss() } label: { Label("RETAKE", systemImage: "video.badge.plus") }
                        .buttonStyle(ServeAISecondaryButtonStyle())
                    PhotosPicker(selection: $replacementItem, matching: .videos) {
                        Label("ANOTHER", systemImage: "folder.fill")
                    }
                    .buttonStyle(ServeAISecondaryButtonStyle())
                }

                Text("This MVP analyzes the full selected clip. Trim in Photos first when the video contains multiple serves.")
                    .font(ServeAITheme.body(.footnote, size: 12))
                    .foregroundStyle(ServeAITheme.mutedInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: 520)
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
        .serveAIBackground()
        .toolbar(.hidden, for: .navigationBar)
        .task(id: videoURL) { await assessRecordingQuality() }
        .onDisappear { player.pause() }
        .onChange(of: replacementItem) { _, item in
            importReplacement(item)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "arrow.left")
                    .frame(width: 44, height: 44)
                    .background(ServeAITheme.elevatedSurface, in: Circle())
            }
            .foregroundStyle(ServeAITheme.ink)
            .accessibilityLabel("Back")
            Text("CHECK THE CLIP")
                .font(ServeAITheme.display(.title3, size: 19))
            Spacer()
        }
    }

    @ViewBuilder
    private var recordingQualityCard: some View {
        if isCheckingQuality {
            HStack(spacing: 12) {
                ProgressView().tint(ServeAITheme.cyan)
                VStack(alignment: .leading, spacing: 3) {
                    Text("CHECKING RECORDING QUALITY")
                        .font(ServeAITheme.body(.subheadline, size: 14, weight: .semibold))
                    Text("Verifying framing, visibility, resolution, and pose tracking")
                        .font(ServeAITheme.body(.caption, size: 12))
                        .foregroundStyle(ServeAITheme.mutedInk)
                }
                Spacer()
            }
            .serveAISurface()
            .accessibilityElement(children: .combine)
        } else if let report = qualityReport {
            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 9) {
                    Image(systemName: qualitySymbol(report.status))
                    Text(report.status.title)
                        .font(ServeAITheme.body(.subheadline, size: 15, weight: .bold))
                    Spacer()
                }
                .foregroundStyle(qualityColor(report.status))

                Text("\(Int((report.poseCoverage * 100).rounded()))% OF SAMPLED FRAMES TRACKED")
                    .font(ServeAITheme.mono(.caption2, size: 9, bold: true))
                    .foregroundStyle(ServeAITheme.mutedInk)

                HStack(spacing: 8) {
                    qualityMetric("POSE", value: report.poseCoverage)
                    Divider().overlay(ServeAITheme.separator)
                    qualityMetric("FULL BODY", value: report.fullBodyCoverage)
                    Divider().overlay(ServeAITheme.separator)
                    qualityMetric("CONF.", value: report.meanPoseConfidence)
                }

                ForEach(report.issues) { issue in
                    VStack(alignment: .leading, spacing: 4) {
                        Label(issue.title, systemImage: issue.severity == .blocking ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .font(ServeAITheme.body(.subheadline, size: 14, weight: .semibold))
                            .foregroundStyle(issue.severity == .blocking ? ServeAITheme.pink : ServeAITheme.orange)
                        Text(issue.detail)
                            .font(ServeAITheme.body(.caption, size: 12))
                            .foregroundStyle(ServeAITheme.mutedInk)
                        Text(issue.recovery)
                            .font(ServeAITheme.body(.caption, size: 12, weight: .medium))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
                }

                if report.issues.isEmpty {
                    Text("The player and major joints are visible consistently enough to continue. This is an input-quality check, not a guarantee that coaching scores are correct.")
                        .font(ServeAITheme.body(.caption, size: 12))
                        .foregroundStyle(ServeAITheme.mutedInk)
                }
            }
            .serveAISurface()
            .accessibilityElement(children: .contain)
        }
    }

    private func qualityMetric(_ label: String, value: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(ServeAITheme.mono(.caption2, size: 8.5, bold: true))
                .foregroundStyle(ServeAITheme.mutedInk)
            Text(value, format: .percent.precision(.fractionLength(0)))
                .font(ServeAITheme.mono(.subheadline, size: 13, bold: true))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    private var primaryButtonTitle: String {
        if isCheckingQuality { return "CHECKING VIDEO" }
        if isPreparing { return "PREPARING CLIP" }
        if qualityReport?.status == .rejected { return "FIX RECORDING TO CONTINUE" }
        return "READ MY SERVE"
    }

    private var canSaveRejectedPilotSample: Bool {
        guard let slot = appModel.activePilotSlot,
              slot.isFailureExample,
              qualityReport?.status == .rejected else { return false }
        return slot.cameraAngle == angle
    }

    private func qualityColor(_ status: RecordingQualityStatus) -> Color {
        switch status {
        case .ready: ServeAITheme.brand
        case .warning: ServeAITheme.orange
        case .rejected: ServeAITheme.pink
        }
    }

    private func qualitySymbol(_ status: RecordingQualityStatus) -> String {
        switch status {
        case .ready: "checkmark.seal.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .rejected: "xmark.octagon.fill"
        }
    }

    private func assessRecordingQuality() async {
        isCheckingQuality = true
        qualityReport = nil
        error = nil
        do {
            qualityReport = try await appModel.recordingQualityAssessor.assess(videoURL: videoURL, cameraAngle: angle)
        } catch is CancellationError {
            return
        } catch let serveError as ServeAIError {
            error = serveError
        } catch {
            self.error = .poseTrackingFailed
        }
        isCheckingQuality = false
    }

    private func saveRejectedPilotSample() {
        guard let slot = appModel.activePilotSlot,
              let qualityReport,
              canSaveRejectedPilotSample else { return }
        isPreparing = true
        error = nil
        player.pause()
        Task {
            do {
                let analysis = try await ResearchCaptureService().makeRejectedSample(
                    videoURL: videoURL,
                    slot: slot,
                    qualityReport: qualityReport
                )
                await MainActor.run {
                    isPreparing = false
                    appModel.finishAnalysis(analysis)
                }
            } catch is CancellationError {
                await MainActor.run { isPreparing = false }
            } catch let serveError as ServeAIError {
                await MainActor.run {
                    isPreparing = false
                    error = serveError
                }
            } catch {
                await MainActor.run {
                    isPreparing = false
                    self.error = .recordingFailed(error.localizedDescription)
                }
            }
        }
    }

    private func importReplacement(_ item: PhotosPickerItem?) {
        guard let item else { return }
        isPreparing = true
        error = nil
        Task {
            do {
                guard let imported = try await item.loadTransferable(type: ImportedVideo.self) else {
                    throw ServeAIError.unsupportedVideo
                }
                isPreparing = false
                appModel.showReview(url: imported.url, angle: angle)
            } catch {
                isPreparing = false
                self.error = .unsupportedVideo
            }
        }
    }

    private func prepareAndAnalyze(_ url: URL) {
        isPreparing = true
        error = nil
        do {
            let savedURL = url.path.contains("/Documents/ServeVideos/") ? url : try VideoStorage.persist(url)
            isPreparing = false
            appModel.startAnalysis(url: savedURL, angle: angle)
        } catch {
            isPreparing = false
            self.error = .insufficientStorage
        }
    }
}

#Preview {
    NavigationStack {
        VideoReviewView(videoURL: URL(fileURLWithPath: "/tmp/serve.mov"), angle: .side)
            .environmentObject(AppViewModel())
    }
}
