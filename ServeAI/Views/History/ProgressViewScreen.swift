import Charts
import SwiftUI

struct ProgressViewScreen: View {
    @Environment(\.dismiss) private var dismiss
    let analyses: [ServeAnalysis]

    private var chronological: [ServeAnalysis] {
        analyses
            .filter { $0.source != .researchCapture }
            .sorted { $0.createdAt < $1.createdAt }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                if chronological.count < 2 {
                    EmptyStateView(
                        symbol: "chart.xyaxis.line",
                        title: "Build a baseline",
                        message: "Complete at least two serve analyses to see estimated score change over time."
                    )
                } else {
                    trendHero
                    chart
                    recentScores
                    comparisonGuide
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
        .serveAIBackground()
        .toolbar(.hidden, for: .navigationBar)
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
            Text("THE TREND")
                .font(ServeAITheme.display(.title3, size: 19))
            Spacer()
        }
    }

    private var trendHero: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                ServeAISectionLabel(text: "CHANGE SINCE FIRST SERVE")
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(change >= 0 ? "+\(change)" : "\(change)")
                        .font(ServeAITheme.display(.largeTitle, size: 52))
                        .foregroundStyle(change >= 0 ? ServeAITheme.brand : ServeAITheme.pink)
                    Text("PTS")
                        .font(ServeAITheme.mono(.caption, size: 11, bold: true))
                        .tracking(0.8)
                        .foregroundStyle(ServeAITheme.mutedInk)
                }
                Text("Practice signal, not an objective measure.")
                    .font(ServeAITheme.body(.caption, size: 12))
                    .foregroundStyle(ServeAITheme.mutedInk)
            }
            Spacer()
            Image(systemName: change >= 0 ? "arrow.up.right" : "arrow.down.right")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(change >= 0 ? ServeAITheme.brand : ServeAITheme.pink)
        }
        .padding(18)
        .background(ServeAITheme.heroGradient, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(ServeAITheme.brand.opacity(0.22)) }
    }

    private var chart: some View {
        Chart(chronological) { analysis in
            AreaMark(
                x: .value("Date", analysis.createdAt),
                y: .value("Score", analysis.overallScore)
            )
            .foregroundStyle(
                LinearGradient(colors: [ServeAITheme.brand.opacity(0.26), ServeAITheme.brand.opacity(0.01)], startPoint: .top, endPoint: .bottom)
            )
            .interpolationMethod(.catmullRom)
            LineMark(
                x: .value("Date", analysis.createdAt),
                y: .value("Score", analysis.overallScore)
            )
            .foregroundStyle(ServeAITheme.brand)
            .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round))
            .interpolationMethod(.catmullRom)
            PointMark(
                x: .value("Date", analysis.createdAt),
                y: .value("Score", analysis.overallScore)
            )
            .foregroundStyle(ServeAITheme.ink)
            .symbolSize(62)
        }
        .chartYScale(domain: max(0, (chronological.map(\.overallScore).min() ?? 40) - 10)...100)
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(ServeAITheme.separator)
                AxisValueLabel().foregroundStyle(ServeAITheme.mutedInk)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated).day()).foregroundStyle(ServeAITheme.mutedInk)
            }
        }
        .frame(height: 260)
        .padding(16)
        .background(ServeAITheme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(ServeAITheme.separator) }
        .accessibilityLabel("Serve score trend. \(change >= 0 ? "Up" : "Down") \(abs(change)) points from first to latest analysis.")
    }

    private var recentScores: some View {
        VStack(alignment: .leading, spacing: 10) {
            ServeAISectionLabel(text: "RECENT READS")
            ForEach(chronological.suffix(4).reversed()) { analysis in
                HStack {
                    Text(analysis.createdAt, format: .dateTime.month(.abbreviated).day())
                        .font(ServeAITheme.mono(.caption, size: 10))
                        .foregroundStyle(ServeAITheme.mutedInk)
                    Spacer()
                    Text(analysis.cameraAngle.title.uppercased())
                        .font(ServeAITheme.mono(.caption2, size: 9))
                        .foregroundStyle(ServeAITheme.faintInk)
                    Text(analysis.overallScore, format: .number)
                        .font(ServeAITheme.display(.title3, size: 20))
                        .foregroundStyle(ServeAITheme.brand)
                        .frame(width: 42, alignment: .trailing)
                }
                .frame(minHeight: 44)
                if analysis.id != chronological.last?.id { Divider().overlay(ServeAITheme.separator) }
            }
        }
        .serveAISurface()
    }

    private var comparisonGuide: some View {
        VStack(alignment: .leading, spacing: 12) {
            ServeAISectionLabel(text: "COMPARE LIKE WITH LIKE")
            Label("Use the same camera angle", systemImage: "camera.viewfinder")
            Label("Keep distance and framing similar", systemImage: "arrow.left.and.right")
            Label("Compare videos with similar lighting", systemImage: "sun.max")
        }
        .font(ServeAITheme.body(.subheadline, size: 14))
        .foregroundStyle(ServeAITheme.ink)
        .serveAISurface()
    }

    private var change: Int {
        guard let first = chronological.first, let last = chronological.last else { return 0 }
        return last.overallScore - first.overallScore
    }
}

#Preview { NavigationStack { ProgressViewScreen(analyses: MockData.history) } }
