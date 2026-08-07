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
    @State private var sourceDuration: TimeInterval?
    @State private var clipStart: TimeInterval = 0
    @State private var clipEnd: TimeInterval = 0
    @State private var preparedClipURL: URL?
    @State private var assessedSelection: VideoClipSelection?
    @State private var playbackBoundaryObserver: Any?
    private let clipExporter: any VideoClipExporting

    private var clipSelection: VideoClipSelection {
        guard let sourceDuration else { return .fullClip(videoURL) }
        if clipStart <= 0.05, clipEnd >= sourceDuration - 0.05 {
            return .fullClip(videoURL)
        }
        return VideoClipSelection(sourceURL: videoURL, startTime: clipStart, endTime: clipEnd)
    }

    private var isCurrentSelectionAssessed: Bool {
        assessedSelection == clipSelection && preparedClipURL != nil && qualityReport != nil
    }

    init(
        videoURL: URL,
        angle: CameraAngle,
        clipExporter: any VideoClipExporting = AVVideoClipExporter()
    ) {
        self.videoURL = videoURL
        self.angle = angle
        self.clipExporter = clipExporter
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
                    Text("\(clipSelection.usesFullClip ? "FULL" : "SELECTED") CLIP · \(angle.title.uppercased())")
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
                        player.seek(to: CMTime(seconds: clipStart, preferredTimescale: 600))
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
                    GuideTag(text: clipSelection.usesFullClip ? "FULL CLIP" : "TRIMMED CLIP")
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                clipSelectionCard
                recordingQualityCard

                if let error {
                    ErrorBanner(error: error, actionTitle: "CHECK AGAIN") {
                        Task { await assessRecordingQuality(for: clipSelection) }
                    }
                }

                Button { prepareAndAnalyze(preparedClipURL ?? clipSelection.sourceURL) } label: {
                    HStack(spacing: 9) {
                        if isPreparing || isCheckingQuality { ProgressView().tint(ServeAITheme.onBrand) }
                        Text(primaryButtonTitle)
                        if !isPreparing, !isCheckingQuality { Image(systemName: "tennisball.fill") }
                    }
                }
                .buttonStyle(ServeAIPrimaryButtonStyle())
                .disabled(
                    isPreparing
                        || isCheckingQuality
                        || !isCurrentSelectionAssessed
                        || qualityReport?.isAcceptable != true
                )

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
            }
            .frame(maxWidth: 520)
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
        .serveAIBackground()
        .toolbar(.hidden, for: .navigationBar)
        .task(id: videoURL) { await loadVideoAndAssess() }
        .onDisappear {
            player.pause()
            removePlaybackBoundaryObserver()
        }
        .onChange(of: clipStart) { _, _ in selectionDidChange(seekToStart: true) }
        .onChange(of: clipEnd) { _, _ in selectionDidChange(seekToStart: false) }
        .onChange(of: replacementItem) { _, item in
            importReplacement(item)
        }
    }

    @ViewBuilder
    private var clipSelectionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("SELECT ONE SERVE")
                    .font(ServeAITheme.body(.subheadline, size: 15, weight: .bold))
                Spacer()
                if sourceDuration != nil {
                    Text(formatDuration(max(0, clipEnd - clipStart)))
                        .font(ServeAITheme.mono(.caption, size: 11, bold: true))
                        .foregroundStyle(ServeAITheme.brand)
                }
            }

            Text("Set the start just before the toss and the end after landing. Only this range is checked and analyzed.")
                .font(ServeAITheme.body(.caption, size: 12))
                .foregroundStyle(ServeAITheme.mutedInk)

            if let sourceDuration, sourceDuration > VideoClipSelection.minimumDuration + 0.05 {
                clipSlider(
                    label: "START",
                    value: $clipStart,
                    range: 0...max(0, clipEnd - VideoClipSelection.minimumDuration)
                )
                clipSlider(
                    label: "END",
                    value: $clipEnd,
                    range: min(sourceDuration, clipStart + VideoClipSelection.minimumDuration)...sourceDuration
                )

                HStack {
                    Text("SOURCE \(formatDuration(sourceDuration))")
                    Spacer()
                    Text("RANGE \(formatDuration(clipStart))–\(formatDuration(clipEnd))")
                }
                .font(ServeAITheme.mono(.caption2, size: 9, bold: true))
                .foregroundStyle(ServeAITheme.faintInk)

                if !isCurrentSelectionAssessed, !isCheckingQuality {
                    Button {
                        Task { await assessRecordingQuality(for: clipSelection) }
                    } label: {
                        Label("CHECK SELECTED CLIP", systemImage: "viewfinder")
                    }
                    .buttonStyle(ServeAISecondaryButtonStyle())
                    .accessibilityHint("Exports this range and checks whether one complete serve is visible")
                }
            } else if sourceDuration != nil {
                Label("This video is too short to contain a complete serve.", systemImage: "exclamationmark.triangle.fill")
                    .font(ServeAITheme.body(.caption, size: 12, weight: .semibold))
                    .foregroundStyle(ServeAITheme.orange)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            } else {
                HStack(spacing: 10) {
                    ProgressView().tint(ServeAITheme.brand)
                    Text("READING VIDEO DURATION")
                        .font(ServeAITheme.mono(.caption, size: 10, bold: true))
                }
                .frame(minHeight: 44)
            }
        }
        .serveAISurface()
    }

    private func clipSlider(
        label: String,
        value: Binding<TimeInterval>,
        range: ClosedRange<TimeInterval>
    ) -> some View {
        VStack(spacing: 6) {
            HStack {
                Text(label)
                    .font(ServeAITheme.mono(.caption2, size: 9, bold: true))
                    .foregroundStyle(ServeAITheme.mutedInk)
                Spacer()
                Text(formatDuration(value.wrappedValue))
                    .font(ServeAITheme.mono(.caption, size: 11, bold: true))
            }
            Slider(value: value, in: range, step: 0.1)
                .tint(ServeAITheme.brand)
                .disabled(isCheckingQuality || isPreparing)
                .accessibilityLabel("Clip \(label.lowercased())")
                .accessibilityValue(formatDuration(value.wrappedValue))
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
        if !isCurrentSelectionAssessed { return "CHECK CLIP FIRST" }
        if qualityReport?.status == .rejected { return "FIX RECORDING TO CONTINUE" }
        return "READ MY SERVE"
    }

    private var canSaveRejectedPilotSample: Bool {
        guard let slot = appModel.activePilotSlot,
              isCurrentSelectionAssessed,
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

    private func loadVideoAndAssess() async {
        isCheckingQuality = true
        error = nil
        do {
            let duration = try await AVURLAsset(url: videoURL).load(.duration).seconds
            guard duration.isFinite, duration > 0 else { throw ServeAIError.corruptedVideo }
            sourceDuration = duration
            clipStart = 0
            clipEnd = duration
            installPlaybackBoundaryObserver()
            await assessRecordingQuality(for: .fullClip(videoURL))
        } catch is CancellationError {
            return
        } catch let serveError as ServeAIError {
            isCheckingQuality = false
            error = serveError
        } catch {
            isCheckingQuality = false
            self.error = .corruptedVideo
        }
    }

    private func assessRecordingQuality(for selection: VideoClipSelection) async {
        isCheckingQuality = true
        qualityReport = nil
        error = nil
        do {
            let preparedURL = try await clipExporter.prepare(selection)
            try Task.checkCancellation()
            let report = try await appModel.recordingQualityAssessor.assess(
                videoURL: preparedURL,
                cameraAngle: angle
            )
            try Task.checkCancellation()
            preparedClipURL = preparedURL
            assessedSelection = selection
            qualityReport = report
        } catch is CancellationError {
            return
        } catch let serveError as ServeAIError {
            error = serveError
        } catch {
            self.error = .poseTrackingFailed
        }
        isCheckingQuality = false
    }

    private func selectionDidChange(seekToStart: Bool) {
        guard sourceDuration != nil, !isCheckingQuality else { return }
        qualityReport = nil
        assessedSelection = nil
        preparedClipURL = nil
        error = nil
        installPlaybackBoundaryObserver()
        if seekToStart {
            player.seek(to: CMTime(seconds: clipStart, preferredTimescale: 600))
        }
    }

    private func installPlaybackBoundaryObserver() {
        removePlaybackBoundaryObserver()
        guard let sourceDuration, clipEnd < sourceDuration - 0.05 else { return }
        let selectedStart = clipStart
        playbackBoundaryObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: CMTime(seconds: clipEnd, preferredTimescale: 600))],
            queue: .main
        ) { [weak player] in
            player?.pause()
            player?.seek(to: CMTime(seconds: selectedStart, preferredTimescale: 600))
        }
    }

    private func removePlaybackBoundaryObserver() {
        guard let playbackBoundaryObserver else { return }
        player.removeTimeObserver(playbackBoundaryObserver)
        self.playbackBoundaryObserver = nil
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        guard duration.isFinite, duration >= 0 else { return "0:00.0" }
        let minutes = Int(duration) / 60
        let seconds = duration - Double(minutes * 60)
        return String(format: "%d:%04.1f", minutes, seconds)
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
                    videoURL: preparedClipURL ?? videoURL,
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
