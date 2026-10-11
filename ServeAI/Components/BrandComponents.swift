import SwiftUI

struct ServeAILogo: View {
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 7 : 9) {
            Image(systemName: "tennisball.fill")
                .font(.system(size: compact ? 11 : 13, weight: .medium))
                .foregroundStyle(ServeAITheme.brand)
            Text("ServeAI")
                .font(ServeAITheme.body(.headline, size: compact ? 14 : 16, weight: .semibold))
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
            Circle().stroke(ServeAITheme.separator, lineWidth: lineWidth)
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
                Text("Serve score")
                    .font(ServeAITheme.mono(.caption2, size: max(8, diameter * 0.06), bold: true))
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
        Label("\(contextLabel) · \(confidence.title)", systemImage: confidence.symbol)
            .font(ServeAITheme.mono(.caption2, size: 10, bold: true))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .foregroundStyle(foreground)
            .background(foreground.opacity(0.10), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
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
        Text(text)
            .font(ServeAITheme.body(.caption, size: 12, weight: .semibold))
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
        .background(ServeAITheme.pink.opacity(0.13), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(ServeAITheme.brand)
                .frame(width: 64, height: 64)
            Text(title)
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
