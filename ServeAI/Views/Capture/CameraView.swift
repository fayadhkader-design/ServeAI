import SwiftUI

struct CameraView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appModel: AppViewModel
    @StateObject private var camera = CameraController()
    let angle: CameraAngle

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraPreview(session: camera.session).ignoresSafeArea()

            VStack {
                HStack {
                    Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 44, height: 44).background(.black.opacity(0.5), in: Circle()) }
                        .accessibilityLabel("Cancel recording")
                    Spacer()
                    Text(angle.title.uppercased())
                        .font(ServeAITheme.mono(.caption, size: 10, bold: true))
                        .tracking(0.8)
                        .foregroundStyle(ServeAITheme.brand)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(ServeAITheme.background.opacity(0.72), in: Capsule())
                    Spacer()
                    Button { camera.switchCamera() } label: { Image(systemName: "arrow.triangle.2.circlepath.camera").frame(width: 44, height: 44).background(.black.opacity(0.5), in: Circle()) }
                        .disabled(camera.isRecording)
                        .accessibilityLabel("Switch camera")
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)

                Spacer()
                AlignmentOverlay(angle: angle)
                Spacer()

                VStack(spacing: 14) {
                    Text(camera.isRecording ? formattedDuration(camera.duration) : "Keep the full body and racket inside the guide")
                        .font(camera.isRecording ? ServeAITheme.mono(.title3, size: 20, bold: true) : ServeAITheme.body(.footnote, size: 12, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.black.opacity(0.55), in: Capsule())
                    Button { camera.toggleRecording() } label: {
                        ZStack {
                            Circle().stroke(.white, lineWidth: 5).frame(width: 78, height: 78)
                            RoundedRectangle(cornerRadius: camera.isRecording ? 7 : 34).fill(.red).frame(width: camera.isRecording ? 32 : 62, height: camera.isRecording ? 32 : 62)
                        }
                        .frame(width: 88, height: 88)
                    }
                    .disabled(!camera.isConfigured)
                    .accessibilityLabel(camera.isRecording ? "Stop recording" : "Start recording")
                }
                .padding(.bottom, 22)
            }

            if let error = camera.error {
                VStack { Spacer(); ErrorBanner(error: error, actionTitle: "Close", action: { dismiss() }).padding() }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .statusBarHidden()
        .task { await camera.configure() }
        .onDisappear { camera.stopSession() }
        .onChange(of: camera.recordedURL) { _, url in
            if let url { appModel.showReview(url: url, angle: angle) }
        }
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        String(format: "%02d:%02d", Int(duration) / 60, Int(duration) % 60)
    }
}

private struct AlignmentOverlay: View {
    let angle: CameraAngle
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 90)
                .stroke(ServeAITheme.brand.opacity(0.78), style: StrokeStyle(lineWidth: 2, dash: [10, 8]))
                .frame(width: 190, height: 360)
            Image(systemName: angle == .side ? "figure.tennis" : "figure.stand")
                .font(.system(size: 88, weight: .thin))
                .foregroundStyle(ServeAITheme.brand.opacity(0.48))
        }
        .accessibilityHidden(true)
    }
}
