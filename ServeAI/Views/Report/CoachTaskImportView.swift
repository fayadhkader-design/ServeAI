import SwiftUI
import UniformTypeIdentifiers

struct CoachTaskImportView: View {
    let existingAnalysisIDs: Set<UUID>
    let onImported: (ServeAnalysis) -> Void

    @State private var manifest: CoachLabelingTaskManifest?
    @State private var isChoosingManifest = false
    @State private var isChoosingVideo = false
    @State private var isWorking = false
    @State private var errorMessage: String?

    private let service = CoachLabelingTaskService()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    ServeAISectionLabel(text: "BLIND COACH REVIEW")
                    Text("IMPORT A COACH TASK")
                        .font(ServeAITheme.display(.title, size: 27))
                    Text("ServeAI verifies the coordinator signature and the exact video before opening a fresh annotation session.")
                        .font(ServeAITheme.body(.body, size: 15))
                        .foregroundStyle(ServeAITheme.mutedInk)
                }

                verificationStep(
                    number: "01",
                    title: "Signed task JSON",
                    detail: manifest.map { "Verified · \($0.coordinatorPseudonym) · key \($0.signerKeyID.prefix(10))…" }
                        ?? "Choose the task manifest sent by the study coordinator.",
                    complete: manifest != nil
                )

                Button(manifest == nil ? "CHOOSE TASK JSON" : "CHOOSE A DIFFERENT TASK") {
                    isChoosingManifest = true
                }
                .buttonStyle(ServeAISecondaryButtonStyle())
                .disabled(isWorking)

                verificationStep(
                    number: "02",
                    title: "Exact source video",
                    detail: manifest.map { "Expected SHA-256 \($0.payload.sourceVideoSHA256.prefix(12))…" }
                        ?? "The task must be verified first.",
                    complete: false
                )

                Button("CHOOSE & VERIFY VIDEO") {
                    isChoosingVideo = true
                }
                .buttonStyle(ServeAIPrimaryButtonStyle())
                .disabled(manifest == nil || isWorking)

                if isWorking {
                    HStack(spacing: 12) {
                        ProgressView().tint(ServeAITheme.brand)
                        Text("Hashing the video on this device…")
                            .font(ServeAITheme.body(.subheadline, size: 14))
                            .foregroundStyle(ServeAITheme.mutedInk)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .serveAISurface()
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(ServeAITheme.body(.subheadline, size: 14))
                        .foregroundStyle(ServeAITheme.pink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .serveAISurface()
                }

                Label(
                    "The task is tamper-evident. The signer fingerprint establishes continuity; study authorization is checked again in the training pipeline.",
                    systemImage: "checkmark.shield.fill"
                )
                .font(ServeAITheme.body(.footnote, size: 13))
                .foregroundStyle(ServeAITheme.mutedInk)
                .serveAISurface()
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
        .scrollIndicators(.hidden)
        .serveAIBackground()
        .navigationTitle("Coach task")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $isChoosingManifest, allowedContentTypes: [.json]) { result in
            loadManifest(result)
        }
        .fileImporter(isPresented: $isChoosingVideo, allowedContentTypes: [.movie]) { result in
            importVideo(result)
        }
    }

    private func verificationStep(number: String, title: String, detail: String, complete: Bool) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(number)
                .font(ServeAITheme.mono(.caption, size: 11, bold: true))
                .foregroundStyle(complete ? ServeAITheme.background : ServeAITheme.brand)
                .frame(width: 38, height: 38)
                .background(complete ? ServeAITheme.brand : ServeAITheme.brand.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title.uppercased())
                    .font(ServeAITheme.display(.headline, size: 16))
                Text(detail)
                    .font(ServeAITheme.body(.caption, size: 13))
                    .foregroundStyle(ServeAITheme.mutedInk)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
            if complete { Image(systemName: "checkmark.seal.fill").foregroundStyle(ServeAITheme.brand) }
        }
        .serveAISurface()
    }

    private func loadManifest(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            manifest = try service.decodeAndVerify(data, existingAnalysisIDs: existingAnalysisIDs)
            errorMessage = nil
        } catch {
            manifest = nil
            errorMessage = error.localizedDescription
        }
    }

    private func importVideo(_ result: Result<URL, Error>) {
        guard let manifest else { return }
        do {
            let url = try result.get()
            isWorking = true
            errorMessage = nil
            Task {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let analysis = try await service.importVerifiedVideo(url, for: manifest)
                    await MainActor.run {
                        isWorking = false
                        onImported(analysis)
                    }
                } catch {
                    await MainActor.run {
                        isWorking = false
                        errorMessage = error.localizedDescription
                    }
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

