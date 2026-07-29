import SwiftUI

struct HomeView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let analyses: [ServeAnalysis]
    let analyze: () -> Void
    let open: (UUID) -> Void
    let showHistory: () -> Void
    let showProgress: () -> Void
    let importCoachTask: () -> Void
    let startPilotCapture: () -> Void

    private var latest: ServeAnalysis? { analyses.first }
    var body: some View {
        ScrollView {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    accessibilityHome
                } else {
                    regularHome
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
    }

    private var regularHome: some View {
        VStack(spacing: 16) {
            homeHeader
            stats
            lastServe
            actionTiles
            Button(action: analyze) {
                HStack {
                    Text("ANALYZE A SERVE")
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                    Spacer()
                    Image(systemName: "arrow.right")
                }
            }
            .buttonStyle(ServeAIPrimaryButtonStyle())
            .accessibilityHint("Opens the recording and upload guide")
        }
    }

    private var accessibilityHome: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(Date.now, format: .dateTime.weekday(.abbreviated).hour().minute())
                    .font(.caption.monospaced())
                    .foregroundStyle(ServeAITheme.mutedInk)
                Spacer()
                profileMenu
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("GO BREAK")
                    .foregroundStyle(ServeAITheme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                Text("SOMETHING.")
                    .foregroundStyle(ServeAITheme.brand)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
            }
            .font(ServeAITheme.display(.caption, size: 20))

            AccessibilityStatRow(symbol: "flame.fill", text: "\(practiceStreak) day streak", color: ServeAITheme.orange)
            AccessibilityStatRow(symbol: "tennisball.fill", text: "\(analyses.count) serves read", color: ServeAITheme.cyan)

            Button(action: latest.map { item in { open(item.id) } } ?? analyze) {
                VStack(alignment: .leading, spacing: 10) {
                    ServeAISectionLabel(text: latest == nil ? "FIRST SERVE" : "LATEST SERVE")
                    if let latest {
                        Text("\(latest.overallScore) OUT OF 100")
                            .foregroundStyle(ServeAITheme.brand)
                        Text(priorityLine(for: latest))
                            .font(.body)
                            .foregroundStyle(ServeAITheme.mutedInk)
                    } else {
                        Text("PUT A SCORE ON THE BOARD")
                        Text("Record one complete motion to start your history.")
                            .font(.body)
                            .foregroundStyle(ServeAITheme.mutedInk)
                    }
                }
                .font(ServeAITheme.display(.caption, size: 18))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .background(ServeAITheme.heroGradient, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(ServeAITheme.brand.opacity(0.22)) }
            }
            .buttonStyle(.plain)

            VStack(spacing: 10) { actionTileItems }

            Button(action: analyze) {
                Label("Analyze a serve", systemImage: "arrow.right")
                    .font(.title2.bold())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                    .foregroundStyle(ServeAITheme.background)
                    .background(ServeAITheme.brand, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the recording and upload guide")
        }
    }

    private var homeHeader: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                Text(Date.now, format: .dateTime.weekday(.abbreviated).hour().minute())
                    .font(ServeAITheme.mono(.caption2, size: 10))
                    .tracking(1.4)
                    .foregroundStyle(ServeAITheme.faintInk)
                    .textCase(.uppercase)
                VStack(alignment: .leading, spacing: 0) {
                    Text("GO BREAK")
                        .foregroundStyle(ServeAITheme.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.55)
                    Text("SOMETHING.")
                        .foregroundStyle(ServeAITheme.brand)
                        .lineLimit(1)
                        .minimumScaleFactor(0.55)
                }
                .font(ServeAITheme.display(.title, size: 27))
                .lineSpacing(-2)
            }
            Spacer()
            profileMenu
        }
    }

    private var profileMenu: some View {
        Menu {
            Button(action: showHistory) { Label("My clips", systemImage: "film.stack") }
            Button(action: showProgress) { Label("Progress", systemImage: "chart.xyaxis.line") }
            Button(action: importCoachTask) { Label("Import coach task", systemImage: "person.crop.rectangle.stack") }
            Button(action: startPilotCapture) { Label("Pilot data capture", systemImage: "checklist.checked") }
        } label: {
            Text("M")
                .font(ServeAITheme.display(.headline, size: 16))
                .foregroundStyle(Color(red: 26 / 255, green: 7 / 255, blue: 16 / 255))
                .frame(width: 46, height: 46)
                .background(
                    LinearGradient(colors: [ServeAITheme.pink, ServeAITheme.orange], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: Circle()
                )
        }
        .accessibilityLabel("Open ServeAI menu")
    }

    private var stats: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 9) { statItems }
            VStack(spacing: 9) { statItems }
        }
    }

    @ViewBuilder
    private var lastServe: some View {
        if let latest {
            Button { open(latest.id) } label: {
                ZStack(alignment: .topTrailing) {
                    Circle()
                        .fill(ServeAITheme.brand.opacity(0.09))
                        .frame(width: 150, height: 150)
                        .offset(x: 36, y: -42)
                    HStack(alignment: .bottom, spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("LAST SERVE · \(latest.createdAt.formatted(.dateTime.weekday(.abbreviated)).uppercased())")
                                .font(ServeAITheme.mono(.caption2, size: 9.5))
                                .tracking(1.1)
                                .foregroundStyle(ServeAITheme.mutedInk)
                            HStack(alignment: .firstTextBaseline, spacing: 5) {
                                Text(latest.overallScore, format: .number)
                                    .font(ServeAITheme.display(.largeTitle, size: 50))
                                    .foregroundStyle(ServeAITheme.brand)
                                Text("/100")
                                    .font(ServeAITheme.display(.caption, size: 14))
                                    .foregroundStyle(ServeAITheme.mutedInk)
                            }
                            Text(priorityLine(for: latest))
                                .font(ServeAITheme.body(.caption, size: 13))
                                .foregroundStyle(ServeAITheme.ink.opacity(0.78))
                                .multilineTextAlignment(.leading)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 4)
                        ScoreBars(scores: analyses.prefix(5).reversed().map(\.overallScore))
                    }
                    .padding(18)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ServeAITheme.heroGradient, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(ServeAITheme.brand.opacity(0.22)) }
                .clipped()
                .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the latest serve report")
        } else {
            Button(action: analyze) {
                HStack(spacing: 14) {
                    Image(systemName: "viewfinder")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(ServeAITheme.brand)
                    VStack(alignment: .leading, spacing: 5) {
                        ServeAISectionLabel(text: "FIRST SERVE")
                        Text("PUT A SCORE ON THE BOARD")
                            .font(ServeAITheme.display(.headline, size: 18))
                            .foregroundStyle(ServeAITheme.ink)
                        Text("Record one complete motion to start your history.")
                            .font(ServeAITheme.body(.caption, size: 13))
                            .foregroundStyle(ServeAITheme.mutedInk)
                    }
                    Spacer()
                    Image(systemName: "arrow.right")
                        .foregroundStyle(ServeAITheme.brand)
                }
                .padding(18)
                .background(ServeAITheme.heroGradient, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(ServeAITheme.brand.opacity(0.22)) }
            }
            .buttonStyle(.plain)
        }
    }

    private var actionTiles: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 9) { actionTileItems }
            VStack(spacing: 9) { actionTileItems }
        }
    }

    @ViewBuilder
    private var statItems: some View {
        StatChip(symbol: "flame.fill", value: "\(practiceStreak)", label: "DAY STREAK", color: ServeAITheme.orange)
        StatChip(symbol: "tennisball.fill", value: "\(analyses.count)", label: "SERVES READ", color: ServeAITheme.cyan)
    }

    @ViewBuilder
    private var actionTileItems: some View {
        HomeActionTile(
            symbol: "bolt.fill",
            title: latest?.drills.first?.name ?? "Toss drill",
            detail: latest == nil ? "analyze to assign" : (latest?.drills.first?.dosage ?? "practice plan"),
            action: latest.map { item in { open(item.id) } } ?? analyze
        )
        HomeActionTile(
            symbol: "film.stack.fill",
            title: "My clips",
            detail: "\(analyses.count) analyzed",
            action: showHistory
        )
    }

    private var practiceStreak: Int {
        let calendar = Calendar.current
        let days = Array(Set(analyses.map { calendar.startOfDay(for: $0.createdAt) })).sorted(by: >)
        guard !days.isEmpty else { return 0 }
        var streak = 1
        for index in 1..<days.count {
            let delta = calendar.dateComponents([.day], from: days[index], to: days[index - 1]).day ?? 0
            if delta == 1 { streak += 1 } else { break }
        }
        return streak
    }

    private func priorityLine(for analysis: ServeAnalysis) -> String {
        if let priority = analysis.mainImprovement {
            return "\(priority.relatedPhase.shortTitle) is the next fix. Let's own it today."
        }
        return "Open the verdict and take one clear priority to court."
    }
}

private struct StatChip: View {
    let symbol: String
    let value: String
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(ServeAITheme.display(.headline, size: 16))
                Text(label)
                    .font(ServeAITheme.mono(.caption2, size: 9, bold: true))
                    .tracking(0.8)
                    .opacity(0.78)
            }
        }
        .foregroundStyle(color)
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .padding(.horizontal, 13)
        .background(color.opacity(0.13), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(color.opacity(0.34)) }
        .accessibilityElement(children: .combine)
    }
}

private struct AccessibilityStatRow: View {
    let symbol: String
    let text: String
    let color: Color

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.title2.bold())
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(color.opacity(0.13), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(color.opacity(0.34)) }
    }
}

private struct ScoreBars: View {
    let scores: [Int]

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(Array(values.enumerated()), id: \.offset) { index, score in
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(ServeAITheme.brand.opacity(index == values.count - 1 ? 1 : 0.28 + Double(index) * 0.09))
                    .frame(width: 12, height: max(24, CGFloat(score) * 0.68))
            }
        }
        .frame(height: 76, alignment: .bottom)
        .accessibilityHidden(true)
    }

    private var values: [Int] {
        if scores.count >= 5 { return Array(scores.suffix(5)) }
        let fallback = [46, 58, 52, 69, 82]
        return Array(fallback.prefix(5 - scores.count)) + scores
    }
}

private struct HomeActionTile: View {
    let symbol: String
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                Image(systemName: symbol)
                    .foregroundStyle(ServeAITheme.brand)
                Text(title)
                    .font(ServeAITheme.display(.subheadline, size: 12))
                    .foregroundStyle(ServeAITheme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(detail)
                    .font(ServeAITheme.body(.caption, size: 11))
                    .foregroundStyle(ServeAITheme.mutedInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
            .padding(13)
            .background(ServeAITheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(ServeAITheme.separator) }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }
}

struct AnalysisRow: View {
    let analysis: ServeAnalysis

    var body: some View {
        HStack(spacing: 14) {
            VideoThumbnailView(
                data: analysis.thumbnailData,
                score: analysis.source == .researchCapture ? nil : analysis.overallScore
            )
            VStack(alignment: .leading, spacing: 4) {
                Text(analysis.createdAt, format: .dateTime.month(.abbreviated).day().year())
                    .font(ServeAITheme.body(.headline, size: 16, weight: .semibold))
                    .foregroundStyle(ServeAITheme.ink)
                Text(
                    analysis.source == .researchCapture
                        ? "Research usability sample · no score"
                        : "\(analysis.cameraAngle.title) · \(analysis.confidence.evidenceQualityTitle)"
                )
                    .font(ServeAITheme.mono(.caption2, size: 10))
                    .foregroundStyle(ServeAITheme.mutedInk)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .foregroundStyle(ServeAITheme.faintInk)
        }
        .frame(minHeight: 64)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            analysis.source == .researchCapture
                ? "\(analysis.createdAt.formatted(date: .abbreviated, time: .omitted)), research usability sample, no coaching score"
                : "\(analysis.createdAt.formatted(date: .abbreviated, time: .omitted)), estimated score \(analysis.overallScore) out of 100, \(analysis.cameraAngle.title), \(analysis.confidence.evidenceQualityTitle)"
        )
        .accessibilityHint("Opens the serve report")
    }
}

#Preview {
    NavigationStack {
        HomeView(
            analyses: MockData.history,
            analyze: {},
            open: { _ in },
            showHistory: {},
            showProgress: {},
            importCoachTask: {},
            startPilotCapture: {}
        )
    }
}
