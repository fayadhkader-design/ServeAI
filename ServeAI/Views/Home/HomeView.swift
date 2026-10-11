import SwiftUI

struct HomeView: View {
    let analyses: [ServeAnalysis]
    let analyze: () -> Void
    let open: (UUID) -> Void
    let showHistory: () -> Void
    let showProgress: () -> Void
    let importCoachTask: () -> Void
    let startPilotCapture: () -> Void

    private var latest: ServeAnalysis? { analyses.first }

    var body: some View {
        ZStack {
            ServeAIBackground(showsSpotlight: true)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    masthead
                    introduction
                    activityStrip
                    latestAnalysis
                    practiceSection
                    recentSection
                }
                .frame(maxWidth: 560, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.top, 10)
                .padding(.bottom, 116)
            }
            .scrollIndicators(.hidden)
        }
        .safeAreaInset(edge: .bottom) {
            analyzeAction
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private var masthead: some View {
        HStack(spacing: 12) {
            ServeAILogo()
            Spacer()
            Label("On-device", systemImage: "lock.fill")
                .font(ServeAITheme.body(.caption, size: 12, weight: .medium))
                .foregroundStyle(ServeAITheme.mutedInk)
            profileMenu
        }
        .frame(minHeight: 48)
        .padding(.bottom, 30)
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("One serve.\nOne clear next move.")
                .font(ServeAITheme.display(.largeTitle, size: 39))
                .tracking(-1.15)
                .foregroundStyle(ServeAITheme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text("Record the full motion and get one evidence-based priority for your next basket.")
                .font(ServeAITheme.body(.body, size: 16))
                .foregroundStyle(ServeAITheme.mutedInk)
                .lineSpacing(4)
                .frame(maxWidth: 430, alignment: .leading)
        }
        .padding(.bottom, 28)
    }

    private var activityStrip: some View {
        HStack(spacing: 0) {
            activityValue("\(analyses.count)", label: "serves read")
            Rectangle().fill(ServeAITheme.separator).frame(width: 1, height: 38).padding(.horizontal, 18)
            activityValue("\(practiceStreak)", label: practiceStreak == 1 ? "day active" : "days active")
            Spacer(minLength: 0)
            Button("View progress", action: showProgress)
                .font(ServeAITheme.body(.subheadline, size: 14, weight: .semibold))
                .foregroundStyle(ServeAITheme.brand)
                .frame(minHeight: 44)
        }
        .padding(.vertical, 17)
        .overlay(alignment: .top) { hairline }
        .overlay(alignment: .bottom) { hairline }
    }

    private func activityValue(_ value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(ServeAITheme.display(.title3, size: 23))
                .foregroundStyle(ServeAITheme.ink)
                .contentTransition(.numericText())
            Text(label)
                .font(ServeAITheme.body(.caption, size: 12))
                .foregroundStyle(ServeAITheme.mutedInk)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var latestAnalysis: some View {
        if let latest {
            Button { open(latest.id) } label: {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Latest analysis")
                            .font(ServeAITheme.display(.title2, size: 24))
                            .foregroundStyle(ServeAITheme.ink)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(ServeAITheme.brand)
                    }

                    HStack(spacing: 12) {
                        Label {
                            Text("Score \(latest.overallScore)")
                        } icon: {
                            Image(systemName: "gauge.with.dots.needle.33percent")
                        }
                        .font(ServeAITheme.body(.headline, size: 17, weight: .semibold))
                        .foregroundStyle(ServeAITheme.brand)
                        .contentTransition(.numericText())
                        Spacer()
                        Text(latest.createdAt, format: .dateTime.month(.abbreviated).day())
                            .font(ServeAITheme.body(.caption, size: 12))
                            .foregroundStyle(ServeAITheme.faintInk)
                    }

                    VStack(alignment: .leading, spacing: 7) {
                        Text(priorityTitle(for: latest))
                            .font(ServeAITheme.body(.headline, size: 17, weight: .semibold))
                            .foregroundStyle(ServeAITheme.ink)
                        Text(priorityLine(for: latest))
                            .font(ServeAITheme.body(.subheadline, size: 14))
                            .foregroundStyle(ServeAITheme.mutedInk)
                            .lineSpacing(3)
                            .multilineTextAlignment(.leading)
                        Text("\(latest.cameraAngle.title) · \(latest.confidence.evidenceQualityTitle)")
                            .font(ServeAITheme.mono(.caption2, size: 10))
                            .foregroundStyle(ServeAITheme.faintInk)
                            .padding(.top, 3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the latest serve report")
        } else {
            Button(action: analyze) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Your first read starts here")
                        .font(ServeAITheme.display(.title2, size: 25))
                        .foregroundStyle(ServeAITheme.ink)
                    Text("Use a side or rear angle, keep the full body and racket visible, and capture one complete motion.")
                        .font(ServeAITheme.body(.body, size: 15))
                        .foregroundStyle(ServeAITheme.mutedInk)
                        .lineSpacing(4)
                    Label("Set up a recording", systemImage: "arrow.right")
                        .font(ServeAITheme.body(.subheadline, size: 15, weight: .semibold))
                        .foregroundStyle(ServeAITheme.brand)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 26)
            }
            .buttonStyle(.plain)
        }
    }

    private var practiceSection: some View {
        Button(action: latest.map { item in { open(item.id) } } ?? analyze) {
            HStack(alignment: .center, spacing: 16) {
                Image(systemName: "figure.tennis")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(ServeAITheme.brand)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Next practice")
                        .font(ServeAITheme.body(.caption, size: 12, weight: .semibold))
                        .foregroundStyle(ServeAITheme.mutedInk)
                    Text(latest?.drills.first?.name ?? "Record one clean serve")
                        .font(ServeAITheme.body(.headline, size: 17, weight: .semibold))
                        .foregroundStyle(ServeAITheme.ink)
                    Text(latest?.drills.first?.dosage ?? "We’ll turn the result into one focused drill.")
                        .font(ServeAITheme.body(.caption, size: 13))
                        .foregroundStyle(ServeAITheme.mutedInk)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(ServeAITheme.faintInk)
            }
            .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .serveAISection()
    }

    @ViewBuilder
    private var recentSection: some View {
        if !analyses.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Recent serves")
                        .font(ServeAITheme.display(.title3, size: 21))
                    Spacer()
                    Button("See all", action: showHistory)
                        .font(ServeAITheme.body(.subheadline, size: 14, weight: .semibold))
                        .foregroundStyle(ServeAITheme.brand)
                        .frame(minHeight: 44)
                }
                .padding(.top, 24)
                .padding(.bottom, 8)

                ForEach(Array(analyses.prefix(3))) { analysis in
                    Button { open(analysis.id) } label: {
                        AnalysisRow(analysis: analysis)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    .overlay(alignment: .top) { hairline }
                }
            }
        }
    }

    private var analyzeAction: some View {
        VStack(spacing: 0) {
            Rectangle().fill(ServeAITheme.separator).frame(height: 1)
            Button(action: analyze) {
                HStack {
                    Text("Analyze a serve")
                    Spacer()
                    Image(systemName: "arrow.right")
                }
            }
            .buttonStyle(ServeAIPrimaryButtonStyle())
            .padding(.horizontal, 22)
            .padding(.top, 12)
            .padding(.bottom, 8)
        }
        .background(ServeAITheme.background)
        .accessibilityHint("Opens the recording and upload guide")
    }

    private var profileMenu: some View {
        Menu {
            Button(action: showHistory) { Label("My clips", systemImage: "film.stack") }
            Button(action: showProgress) { Label("Progress", systemImage: "chart.xyaxis.line") }
            Button(action: importCoachTask) { Label("Import coach task", systemImage: "person.crop.rectangle.stack") }
            Button(action: startPilotCapture) { Label("Pilot data capture", systemImage: "checklist.checked") }
        } label: {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(ServeAITheme.ink)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Open ServeAI menu")
    }

    private var hairline: some View {
        Rectangle().fill(ServeAITheme.separator).frame(height: 1)
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

    private func priorityTitle(for analysis: ServeAnalysis) -> String {
        analysis.mainImprovement?.title ?? "Review the available evidence"
    }

    private func priorityLine(for analysis: ServeAnalysis) -> String {
        analysis.mainImprovement?.correction ?? "The view is limited. Use a stable side or rear angle before changing your technique."
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
                        ? "Research sample · no score"
                        : "\(analysis.cameraAngle.title) · \(analysis.confidence.evidenceQualityTitle)"
                )
                .font(ServeAITheme.body(.caption, size: 12))
                .foregroundStyle(ServeAITheme.mutedInk)
            }
            Spacer()
            if analysis.source != .researchCapture {
                Text(analysis.overallScore, format: .number)
                    .font(ServeAITheme.display(.title3, size: 21))
                    .foregroundStyle(ServeAITheme.brand)
                    .contentTransition(.numericText())
            }
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(ServeAITheme.faintInk)
        }
        .frame(minHeight: 64)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            analysis.source == .researchCapture
                ? "\(analysis.createdAt.formatted(date: .abbreviated, time: .omitted)), research sample, no coaching score"
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
