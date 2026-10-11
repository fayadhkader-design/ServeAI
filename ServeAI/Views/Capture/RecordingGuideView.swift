import PhotosUI
import SwiftUI

struct RecordingGuideView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appModel: AppViewModel
    @State private var angle: CameraAngle = .side
    @State private var photoItem: PhotosPickerItem?
    @State private var importedURL: URL?
    @State private var isImporting = false
    @State private var importError: ServeAIError?

    private var pilotSlot: CapturePlanSlot? { appModel.activePilotSlot }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                anglePicker
                if let pilotSlot { pilotBrief(pilotSlot) }

                PhotosPicker(selection: $photoItem, matching: .videos) {
                    DropZone(
                        isImporting: isImporting,
                        filename: importedURL?.lastPathComponent
                    )
                }
                .buttonStyle(.plain)
                .disabled(isImporting)

                HStack(spacing: 9) {
                    Button { appModel.showCamera(angle: angle) } label: {
                        Label("Record now", systemImage: "video.fill")
                    }
                    .foregroundStyle(ServeAITheme.ink)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(ServeAITheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                    PhotosPicker(selection: $photoItem, matching: .videos) {
                        Label("Camera roll", systemImage: "folder.fill")
                            .frame(maxWidth: .infinity, minHeight: 52)
                    }
                    .foregroundStyle(ServeAITheme.ink)
                    .background(ServeAITheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .font(ServeAITheme.body(.subheadline, size: 14, weight: .semibold))

                guideTags

                if let importError {
                    ErrorBanner(error: importError)
                }

                Button {
                    if let importedURL { appModel.showReview(url: importedURL, angle: angle) }
                } label: {
                    HStack(spacing: 9) {
                        if isImporting { ProgressView().tint(ServeAITheme.onBrand) }
                        Text(importedURL == nil ? "Add a clip first" : "Analyze this serve")
                        if importedURL != nil { Image(systemName: "tennisball.fill") }
                    }
                }
                .buttonStyle(ServeAIPrimaryButtonStyle())
                .disabled(importedURL == nil || isImporting)
            }
            .frame(maxWidth: 520)
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
        .serveAIBackground()
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            if let pilotSlot { angle = pilotSlot.cameraAngle }
        }
        .onChange(of: photoItem) { _, item in
            importVideo(item)
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
            Text("Choose a serve")
                .font(ServeAITheme.display(.title2, size: 25))
            Spacer()
        }
    }

    private var anglePicker: some View {
        Picker("Camera angle", selection: $angle) {
            ForEach(CameraAngle.allCases) { cameraAngle in
                Text(cameraAngle.title).tag(cameraAngle)
            }
        }
        .font(ServeAITheme.mono(.caption2, size: 10, bold: true))
        .pickerStyle(.segmented)
        .disabled(pilotSlot != nil)
        .accessibilityHint("Choose the view used to record the serve")
    }

    private var guideTags: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { tagItems }
            VStack(alignment: .leading, spacing: 6) { tagItems }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var tagItems: some View {
        GuideTag(text: angle == .side ? "SIDE ANGLE" : "REAR ANGLE")
        if let pilotSlot, pilotSlot.isFailureExample {
            GuideTag(text: pilotSlot.recordingIssueTags.map { $0.title.uppercased() }.joined(separator: " · "))
        } else {
            GuideTag(text: "FULL BODY IN FRAME")
        }
        GuideTag(text: "3–8 SECONDS")
    }

    private func pilotBrief(_ slot: CapturePlanSlot) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label(slot.slotID.uppercased(), systemImage: "checklist.checked")
                Spacer()
                Text(slot.participantPseudonym.uppercased())
            }
            .font(ServeAITheme.mono(.caption2, size: 9.5, bold: true))
            .foregroundStyle(ServeAITheme.cyan)

            Text("\(slot.cameraAngle.title) · \(slot.skillLevel.title) · \(slot.resolution.title) · \(slot.frameRate.title)")
                .font(ServeAITheme.body(.subheadline, size: 14, weight: .semibold))

            if slot.isFailureExample {
                Text("Research-only failure capture. Introduce \(slot.recordingIssueTags.map { $0.title.lowercased() }.joined(separator: ", ")) during part of the clip, while retaining at least two clear seconds. A rejected quality check may be saved for labeling but will never produce coaching.")
                    .font(ServeAITheme.body(.caption, size: 12))
                    .foregroundStyle(ServeAITheme.mutedInk)
            } else {
                Text("The selected view is locked to the frozen slot. The signed task will also verify the observed resolution and frame rate.")
                    .font(ServeAITheme.body(.caption, size: 12))
                    .foregroundStyle(ServeAITheme.mutedInk)
            }
        }
        .padding(15)
        .background(ServeAITheme.cyan.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(ServeAITheme.cyan.opacity(0.28)) }
        .accessibilityElement(children: .combine)
    }

    private func importVideo(_ item: PhotosPickerItem?) {
        guard let item else { return }
        isImporting = true
        importedURL = nil
        importError = nil
        Task {
            do {
                guard let video = try await item.loadTransferable(type: ImportedVideo.self) else {
                    throw ServeAIError.unsupportedVideo
                }
                importedURL = video.url
                isImporting = false
            } catch {
                isImporting = false
                importError = .unsupportedVideo
            }
        }
    }
}

private struct DropZone: View {
    let isImporting: Bool
    let filename: String?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(filename == nil ? ServeAITheme.ink.opacity(0.04) : ServeAITheme.brand.opacity(0.09))
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    filename == nil ? ServeAITheme.ink.opacity(0.24) : ServeAITheme.brand.opacity(0.56),
                    style: StrokeStyle(lineWidth: 1, dash: [7, 7])
                )
            ServeAICourtTexture(opacity: 0.035)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(spacing: 12) {
                if isImporting {
                    ProgressView()
                        .controlSize(.large)
                        .tint(ServeAITheme.brand)
                } else {
                    Image(systemName: filename == nil ? "arrow.up.circle.fill" : "film.fill")
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundStyle(filename == nil ? ServeAITheme.ink : ServeAITheme.brand)
                }
                Text(isImporting ? "Importing your serve" : (filename ?? "Tap to add your serve"))
                    .font(ServeAITheme.body(.headline, size: 17, weight: .semibold))
                    .foregroundStyle(ServeAITheme.ink)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                Text(filename == nil ? "Record now or choose a video from your camera roll." : "The clip is ready. Check the view before analysis.")
                    .font(ServeAITheme.body(.subheadline, size: 14))
                    .foregroundStyle(ServeAITheme.mutedInk)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }
            .padding(28)
        }
        .frame(minHeight: 300)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(filename == nil ? "Choose a serve video" : "Selected video \(filename ?? "")")
    }
}

struct GuideTag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(ServeAITheme.mono(.caption2, size: 9.5))
            .tracking(0.5)
            .foregroundStyle(ServeAITheme.mutedInk)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(ServeAITheme.surface, in: Capsule())
    }
}

#Preview {
    NavigationStack { RecordingGuideView().environmentObject(AppViewModel()) }
}
