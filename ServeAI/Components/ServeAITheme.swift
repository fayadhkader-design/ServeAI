import SwiftUI

enum ServeAITheme {
    // Claude Design reference palette.
    static let background = Color(red: 8 / 255, green: 21 / 255, blue: 15 / 255)
    static let deepSurface = Color(red: 12 / 255, green: 31 / 255, blue: 22 / 255)
    static let surface = ink.opacity(0.06)
    static let elevatedSurface = ink.opacity(0.10)
    static let separator = ink.opacity(0.12)

    static let ink = Color(red: 243 / 255, green: 245 / 255, blue: 232 / 255)
    static let mutedInk = ink.opacity(0.58)
    static let faintInk = ink.opacity(0.38)
    static let brand = Color(red: 198 / 255, green: 1, blue: 61 / 255)
    static let cyan = Color(red: 70 / 255, green: 213 / 255, blue: 1)
    static let pink = Color(red: 1, green: 61 / 255, blue: 154 / 255)
    static let orange = Color(red: 1, green: 138 / 255, blue: 61 / 255)
    static let onBrand = background
    static let courtGold = orange

    static let heroGradient = LinearGradient(
        colors: [Color(red: 25 / 255, green: 96 / 255, blue: 60 / 255), Color(red: 10 / 255, green: 46 / 255, blue: 30 / 255)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static func display(_ style: Font.TextStyle = .title, size: CGFloat) -> Font {
        .custom("ArchivoBlack-Regular", size: size, relativeTo: style)
    }

    static func body(_ style: Font.TextStyle = .body, size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let name: String
        switch weight {
        case .bold: name = "SpaceGrotesk-Bold"
        case .semibold: name = "SpaceGrotesk-SemiBold"
        case .medium: name = "SpaceGrotesk-Medium"
        default: name = "SpaceGrotesk-Regular"
        }
        return .custom(name, size: size, relativeTo: style)
    }

    static func mono(_ style: Font.TextStyle = .caption, size: CGFloat, bold: Bool = false) -> Font {
        .custom(bold ? "JetBrainsMono-Bold" : "JetBrainsMono-Regular", size: size, relativeTo: style)
    }
}

struct ServeAICourtTexture: View {
    var opacity = 0.05

    var body: some View {
        Canvas { context, size in
            var path = Path()
            let run = size.height * 0.47
            for startX in stride(from: -size.height, through: size.width + size.height, by: 22) {
                path.move(to: CGPoint(x: startX, y: 0))
                path.addLine(to: CGPoint(x: startX - run, y: size.height))
            }
            context.stroke(path, with: .color(ServeAITheme.brand.opacity(opacity)), lineWidth: 0.7)
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

struct ServeAIBackground: View {
    var body: some View {
        ZStack {
            ServeAITheme.background
            ServeAICourtTexture()
        }
        .ignoresSafeArea()
    }
}

struct ServeAIPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ServeAITheme.display(.headline, size: 17))
            .foregroundStyle(ServeAITheme.onBrand.opacity(isEnabled ? 1 : 0.48))
            .frame(maxWidth: .infinity, minHeight: 58)
            .padding(.horizontal, 18)
            .background(isEnabled ? ServeAITheme.brand : ServeAITheme.ink.opacity(0.09), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .opacity(configuration.isPressed ? 0.84 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

struct ServeAISecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ServeAITheme.display(.subheadline, size: 13))
            .foregroundStyle(isEnabled ? ServeAITheme.ink : ServeAITheme.faintInk)
            .frame(maxWidth: .infinity, minHeight: 52)
            .padding(.horizontal, 16)
            .background(ServeAITheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(ServeAITheme.separator) }
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
    }
}

struct SurfaceModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(ServeAITheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(ServeAITheme.separator) }
    }
}

extension View {
    func serveAISurface() -> some View { modifier(SurfaceModifier()) }

    func serveAIBackground() -> some View {
        background { ServeAIBackground() }
            .foregroundStyle(ServeAITheme.ink)
    }
}
