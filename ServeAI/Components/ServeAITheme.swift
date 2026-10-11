import SwiftUI

enum ServeAITheme {
    // An editorial, court-side palette: warm chalk, graphite, and one muted grass accent.
    static let background = Color(red: 11 / 255, green: 13 / 255, blue: 11 / 255)
    static let deepSurface = Color(red: 16 / 255, green: 18 / 255, blue: 16 / 255)
    static let surface = Color(red: 22 / 255, green: 25 / 255, blue: 21 / 255)
    static let elevatedSurface = Color(red: 29 / 255, green: 32 / 255, blue: 27 / 255)
    static let separator = Color(red: 242 / 255, green: 241 / 255, blue: 232 / 255).opacity(0.13)

    static let ink = Color(red: 242 / 255, green: 241 / 255, blue: 232 / 255)
    static let mutedInk = Color(red: 177 / 255, green: 179 / 255, blue: 169 / 255)
    static let faintInk = Color(red: 126 / 255, green: 130 / 255, blue: 120 / 255)
    static let brand = Color(red: 197 / 255, green: 207 / 255, blue: 168 / 255)
    static let onBrand = Color(red: 19 / 255, green: 22 / 255, blue: 17 / 255)

    // Compatibility aliases now behave as semantic colors instead of neon decoration.
    static let cyan = Color(red: 143 / 255, green: 170 / 255, blue: 160 / 255)
    static let pink = Color(red: 201 / 255, green: 123 / 255, blue: 120 / 255)
    static let orange = Color(red: 213 / 255, green: 154 / 255, blue: 111 / 255)
    static let courtGold = orange

    // Kept for existing screens, but intentionally resolves to a calm tonal surface.
    static let heroGradient = LinearGradient(
        colors: [Color(red: 27 / 255, green: 31 / 255, blue: 25 / 255), Color(red: 21 / 255, green: 24 / 255, blue: 20 / 255)],
        startPoint: .top,
        endPoint: .bottom
    )

    static func display(_ style: Font.TextStyle = .title, size: CGFloat) -> Font {
        .system(size: size, weight: .semibold, design: .serif)
    }

    static func body(_ style: Font.TextStyle = .body, size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    static func mono(_ style: Font.TextStyle = .caption, size: CGFloat, bold: Bool = false) -> Font {
        .system(size: size, weight: bold ? .semibold : .regular, design: .monospaced)
    }
}

struct ServeAIGrain: View {
    var opacity = 0.035

    var body: some View {
        Canvas { context, size in
            // Deterministic points produce a quiet printed grain without a repeating grid.
            for index in 0..<210 {
                let x = CGFloat((index * 73) % 211) / 211 * size.width
                let y = CGFloat((index * 131) % 223) / 223 * size.height
                let radius = CGFloat((index % 3) + 1) * 0.35
                context.fill(
                    Path(ellipseIn: CGRect(x: x, y: y, width: radius, height: radius)),
                    with: .color(ServeAITheme.ink.opacity(opacity))
                )
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

struct ServeAISpotlight: View {
    var body: some View {
        RadialGradient(
            colors: [ServeAITheme.brand.opacity(0.11), .clear],
            center: UnitPoint(x: 0.12, y: 0.08),
            startRadius: 0,
            endRadius: 330
        )
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

struct ServeAICourtTexture: View {
    var opacity = 0.035
    var body: some View { ServeAIGrain(opacity: opacity) }
}

struct ServeAIBackground: View {
    var showsSpotlight = false

    var body: some View {
        ZStack {
            ServeAITheme.background
            if showsSpotlight { ServeAISpotlight() }
            ServeAIGrain()
        }
        .ignoresSafeArea()
    }
}

struct ServeAIPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ServeAITheme.body(.headline, size: 17, weight: .semibold))
            .foregroundStyle(ServeAITheme.onBrand.opacity(isEnabled ? 1 : 0.52))
            .frame(maxWidth: .infinity, minHeight: 56)
            .padding(.horizontal, 18)
            .background(isEnabled ? ServeAITheme.brand : ServeAITheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .opacity(configuration.isPressed ? 0.84 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.975 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

struct ServeAISecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ServeAITheme.body(.subheadline, size: 15, weight: .semibold))
            .foregroundStyle(isEnabled ? ServeAITheme.ink : ServeAITheme.faintInk)
            .frame(maxWidth: .infinity, minHeight: 52)
            .padding(.horizontal, 16)
            .background(ServeAITheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(ServeAITheme.separator) }
            .opacity(configuration.isPressed ? 0.72 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
    }
}

struct SurfaceModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(ServeAITheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct EditorialSectionModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.vertical, 18)
            .overlay(alignment: .top) { Rectangle().fill(ServeAITheme.separator).frame(height: 1) }
    }
}

extension View {
    func serveAISurface() -> some View { modifier(SurfaceModifier()) }
    func serveAISection() -> some View { modifier(EditorialSectionModifier()) }

    func serveAIBackground() -> some View {
        background { ServeAIBackground() }
            .foregroundStyle(ServeAITheme.ink)
    }
}
