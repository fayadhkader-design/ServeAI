import AVKit
import SwiftUI

struct FrameReviewView: View {
    @Environment(\.dismiss) private var dismiss
    let analysis: ServeAnalysis
    @State private var selectedIndex = 0
    @State private var player: AVPlayer?
    @State private var isPlaying = false

    private var phases: [PhaseScore] { analysis.phaseScores }
    private var selected: PhaseScore? {
        guard phases.indices.contains(selectedIndex) else { return nil }
        return phases[selectedIndex]
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                header
                frameStage
                playbackControls
                phaseStrip
                navigationControls
            }
            .frame(maxWidth: 560)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
        .serveAIBackground()
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            if let url = analysis.videoURL, FileManager.default.fileExists(atPath: url.path) {
                player = AVPlayer(url: url)
            }
        }
        .onDisappear { player?.pause() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "arrow.left")
                    .frame(width: 44, height: 44)
                    .background(ServeAITheme.elevatedSurface, in: Circle())
            }
            .foregroundStyle(ServeAITheme.ink)
            .accessibilityLabel("Back to verdict")
            Text("FRAME BY FRAME")
                .font(ServeAITheme.display(.title3, size: 18))
            Spacer()
        }
        .padding(.horizontal, 20)
    }

    private var frameStage: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(ServeAITheme.deepSurface)
            if let player {
                VideoPlayer(player: player)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .accessibilityLabel("Analyzed serve video")
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "film")
                        .font(.system(size: 34, weight: .medium))
                    Text("SERVE FOOTAGE UNAVAILABLE")
                        .font(ServeAITheme.mono(.caption, size: 10, bold: true))
                        .tracking(1)
                }
                .foregroundStyle(ServeAITheme.faintInk)
            }

            VStack {
                HStack {
                    Text("\(phaseTime) · \(selected?.phase.shortTitle.uppercased() ?? "PHASE")")
                        .font(ServeAITheme.mono(.caption2, size: 9.5, bold: true))
                        .tracking(0.6)
                        .foregroundStyle(ServeAITheme.brand)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(ServeAITheme.background.opacity(0.82), in: Capsule())
                    Spacer()
                    Text(phaseTag)
                        .font(ServeAITheme.display(.caption, size: 10))
                        .foregroundStyle(ServeAITheme.background)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(phaseColor, in: Capsule())
                }
                Spacer()
                Text(selected?.note ?? "No phase note is available.")
                    .font(ServeAITheme.body(.caption, size: 13))
                    .foregroundStyle(ServeAITheme.ink)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(ServeAITheme.background.opacity(0.88), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(ServeAITheme.separator) }
            }
            .padding(12)
        }
        .aspectRatio(3 / 4, contentMode: .fit)
        .overlay { RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(ServeAITheme.separator) }
        .padding(.horizontal, 20)
    }

    private var playbackControls: some View {
        HStack(spacing: 12) {
            Button {
                guard let player else { return }
                isPlaying.toggle()
                if isPlaying { player.play() } else { player.pause() }
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .foregroundStyle(ServeAITheme.background)
                    .frame(width: 44, height: 44)
                    .background(ServeAITheme.brand, in: Circle())
            }
            .disabled(player == nil)
            .accessibilityLabel(isPlaying ? "Pause video" : "Play video")

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(ServeAITheme.ink.opacity(0.12)).frame(height: 8)
                    Capsule().fill(ServeAITheme.brand)
                        .frame(width: max(8, geometry.size.width * phaseProgress), height: 8)
                    Circle()
                        .fill(ServeAITheme.ink)
                        .frame(width: 18, height: 18)
                        .offset(x: max(0, geometry.size.width * phaseProgress - 9))
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 44)
            .accessibilityHidden(true)

            Text(phaseTime)
                .font(ServeAITheme.mono(.caption2, size: 10))
                .foregroundStyle(ServeAITheme.mutedInk)
        }
        .padding(.horizontal, 20)
    }

    private var phaseStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 9) {
                ForEach(Array(phases.enumerated()), id: \.element.id) { index, phase in
                    Button {
                        select(index)
                    } label: {
                        VStack(spacing: 7) {
                            ZStack(alignment: .topTrailing) {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(ServeAITheme.deepSurface)
                                    .frame(width: 82, height: 104)
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .stroke(index == selectedIndex ? color(for: phase) : ServeAITheme.separator, lineWidth: index == selectedIndex ? 2 : 1)
                                    }
                                Image(systemName: phase.phase == .ballToss ? "arrow.up" : "figure.tennis")
                                    .font(.system(size: 25, weight: .light))
                                    .foregroundStyle(ServeAITheme.ink.opacity(index == selectedIndex ? 0.72 : 0.30))
                                    .frame(width: 82, height: 104)
                                Circle()
                                    .fill(color(for: phase))
                                    .frame(width: 8, height: 8)
                                    .padding(7)
                            }
                            Text(phase.phase.shortTitle.uppercased())
                                .font(ServeAITheme.display(.caption2, size: 9))
                                .foregroundStyle(index == selectedIndex ? color(for: phase) : ServeAITheme.faintInk)
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                                .frame(width: 82)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(phase.phase.title), \(phase.score.map { "\($0) out of 100" } ?? "insufficient visibility")")
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
    }

    private var navigationControls: some View {
        HStack(spacing: 9) {
            Button { select(max(0, selectedIndex - 1)) } label: {
                Label("PREV", systemImage: "arrow.left")
            }
            .buttonStyle(ServeAISecondaryButtonStyle())
            .disabled(selectedIndex == 0)

            Button { select(min(phases.count - 1, selectedIndex + 1)) } label: {
                HStack { Text("NEXT"); Image(systemName: "arrow.right") }
            }
            .font(ServeAITheme.display(.caption, size: 13))
            .foregroundStyle(ServeAITheme.brand)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(ServeAITheme.brand.opacity(0.14), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(ServeAITheme.brand.opacity(0.36)) }
            .disabled(selectedIndex >= phases.count - 1)
        }
        .padding(.horizontal, 20)
    }

    private var phaseProgress: CGFloat {
        guard phases.count > 1 else { return 0 }
        return CGFloat(selectedIndex) / CGFloat(phases.count - 1)
    }

    private var phaseTime: String {
        let seconds = analysis.videoMetadata.duration * Double(phaseProgress)
        return String(format: "%.1fs", seconds)
    }

    private var phaseColor: Color {
        selected.map(color(for:)) ?? ServeAITheme.faintInk
    }

    private var phaseTag: String {
        guard let score = selected?.score else { return "LIMITED" }
        if score >= 80 { return "GOOD" }
        if score >= 70 { return "WORK" }
        return "FIX"
    }

    private func color(for phase: PhaseScore) -> Color {
        guard let score = phase.score else { return ServeAITheme.faintInk }
        if score >= 80 { return ServeAITheme.brand }
        if score >= 70 { return ServeAITheme.cyan }
        if score >= 60 { return ServeAITheme.orange }
        return ServeAITheme.pink
    }

    private func select(_ index: Int) {
        guard phases.indices.contains(index) else { return }
        selectedIndex = index
        isPlaying = false
        player?.pause()
        let seconds = analysis.videoMetadata.duration * Double(index) / Double(max(1, phases.count - 1))
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
    }
}

#Preview { NavigationStack { FrameReviewView(analysis: MockData.analysis()) } }
