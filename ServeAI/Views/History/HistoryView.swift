import SwiftUI

struct HistoryView: View {
    @Environment(\.dismiss) private var dismiss
    let analyses: [ServeAnalysis]
    let open: (UUID) -> Void
    let delete: (ServeAnalysis) -> Void
    @State private var pendingDeletion: ServeAnalysis?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header

                if analyses.isEmpty {
                    EmptyStateView(
                        symbol: "film.stack",
                        title: "No clips yet",
                        message: "Completed verdicts are stored on this device and will appear here."
                    )
                } else {
                    HStack {
                        ServeAISectionLabel(text: "\(analyses.count) CLIPS STORED")
                        Spacer()
                        Text("ON THIS IPHONE")
                            .font(ServeAITheme.mono(.caption2, size: 9))
                            .tracking(0.6)
                            .foregroundStyle(ServeAITheme.faintInk)
                    }

                    LazyVStack(spacing: 10) {
                        ForEach(analyses) { analysis in
                            HistoryCard(
                                analysis: analysis,
                                open: { open(analysis.id) },
                                requestDelete: { pendingDeletion = analysis }
                            )
                        }
                    }

                    Label("Reports and ServeAI’s private video copies stay on this device.", systemImage: "lock.shield.fill")
                        .font(ServeAITheme.body(.footnote, size: 12))
                        .foregroundStyle(ServeAITheme.faintInk)
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
        .serveAIBackground()
        .toolbar(.hidden, for: .navigationBar)
        .alert("Delete this analysis?", isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })) {
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
            Button("Delete", role: .destructive) {
                if let pendingDeletion { delete(pendingDeletion) }
                pendingDeletion = nil
            }
        } message: {
            Text("The report and ServeAI’s private video copy will be removed from this device. The original in Photos is not affected. This cannot be undone.")
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
            Text("MY CLIPS")
                .font(ServeAITheme.display(.title3, size: 19))
            Spacer()
        }
    }
}

private struct HistoryCard: View {
    let analysis: ServeAnalysis
    let open: () -> Void
    let requestDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 10) {
                    AnalysisRow(analysis: analysis)
                    HStack(spacing: 8) {
                        if let best = analysis.highestScoringPhase {
                            PhaseChip(title: "BEST · \(best.phase.shortTitle)", color: ServeAITheme.brand)
                        }
                        if let priority = analysis.mainImprovement {
                            PhaseChip(title: "FIX · \(priority.relatedPhase.shortTitle)", color: ServeAITheme.pink)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: requestDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(ServeAITheme.pink)
                    .frame(width: 44, height: 44)
                    .background(ServeAITheme.pink.opacity(0.10), in: Circle())
            }
            .accessibilityLabel("Delete analysis from \(analysis.createdAt.formatted(date: .abbreviated, time: .omitted))")
        }
        .padding(14)
        .background(ServeAITheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(ServeAITheme.separator) }
        .contextMenu {
            Button(role: .destructive, action: requestDelete) {
                Label("Delete analysis", systemImage: "trash")
            }
        }
    }
}

private struct PhaseChip: View {
    let title: String
    let color: Color

    var body: some View {
        Text(title.uppercased())
            .font(ServeAITheme.mono(.caption2, size: 8.5, bold: true))
            .tracking(0.4)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(color.opacity(0.10), in: Capsule())
    }
}

#Preview { NavigationStack { HistoryView(analyses: MockData.history, open: { _ in }, delete: { _ in }) } }
