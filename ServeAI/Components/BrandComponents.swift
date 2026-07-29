import SwiftUI

struct ServeAILogo: View {
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 8 : 10) {
            Circle()
                .fill(ServeAITheme.brand)
                .frame(width: compact ? 8 : 10, height: compact ? 8 : 10)
            Text("SERVE AI")
                .font(ServeAITheme.display(.headline, size: compact ? 13 : 15))
                .tracking(compact ? 1.6 : 2.6)
                .foregroundStyle(ServeAITheme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Serve A I")
    }
}

struct ScoreRing: View {
    let score: Int
    var diameter: CGFloat = 156
    var lineWidth: CGFloat = 13

    var body: some View {
        ZStack {
            Circle().stroke(ServeAITheme.ink.opacity(0.12), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(max(0, min(100, score))) / 100)
                .stroke(ServeAITheme.brand, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 4) {
                Text(score, format: .number)
                    .font(ServeAITheme.display(.largeTitle, size: diameter * 0.34))
                    .foregroundStyle(ServeAITheme.ink)
                    .contentTransition(.numericText())
                    .minimumScaleFactor(0.6)
                Text("SERVE SCORE")
                    .font(ServeAITheme.mono(.caption2, size: max(8, diameter * 0.06), bold: true))
                    .tracking(1.2)
                    .foregroundStyle(ServeAITheme.brand)
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Estimated overall serve score")
        .accessibilityValue("\(score) out of 100")
    }
}

struct EvidenceQualityBadge: View {
    let confidence: ConfidenceLevel
    var contextLabel = "Video evidence"

    var body: some View {
        Label("\(contextLabel.uppercased()) · \(confidence.title.uppercased())", systemImage: confidence.symbol)
            .font(ServeAITheme.mono(.caption2, size: 10, bold: true))
            .tracking(0.7)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .foregroundStyle(foreground)
            .background(foreground.opacity(0.14), in: Capsule())
            .overlay { Capsule().stroke(foreground.opacity(0.30)) }
            .accessibilityLabel("\(contextLabel): \(confidence.title)")
    }

    private var foreground: Color {
        switch confidence {
        case .low: ServeAITheme.pink
        case .medium: ServeAITheme.orange
        case .high: ServeAITheme.brand
        }
    }
}

struct ServeAISectionLabel: View {
    let text: String
    var color = ServeAITheme.brand

    var body: some View {
        Text(text.uppercased())
            .font(ServeAITheme.mono(.caption2, size: 10, bold: true))
            .tracking(1.4)
            .foregroundStyle(color)
    }
}

struct ErrorBanner: View {
    let error: ServeAIError
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(error.errorDescription ?? "Something went wrong", systemImage: "exclamationmark.triangle.fill")
                .font(ServeAITheme.body(.headline, size: 17, weight: .semibold))
            if let suggestion = error.recoverySuggestion {
                Text(suggestion)
                    .font(ServeAITheme.body(.subheadline, size: 14))
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(ServeAITheme.body(.subheadline, size: 14, weight: .semibold))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .foregroundStyle(ServeAITheme.ink)
        .background(ServeAITheme.pink.opacity(0.15), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(ServeAITheme.pink.opacity(0.38)) }
        .accessibilityElement(children: .combine)
    }
}

struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: symbol)
                .font(.system(size: 38, weight: .medium))
                .foregroundStyle(ServeAITheme.brand)
                .frame(width: 78, height: 78)
                .background(ServeAITheme.brand.opacity(0.10), in: Circle())
            Text(title.uppercased())
                .font(ServeAITheme.display(.title2, size: 21))
                .multilineTextAlignment(.center)
            Text(message)
                .font(ServeAITheme.body(.body, size: 16))
                .foregroundStyle(ServeAITheme.mutedInk)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(ServeAIPrimaryButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, minHeight: 340)
        .padding(24)
        .accessibilityElement(children: .contain)
    }
}
