import SwiftUI

struct OnboardingView: View {
    @Binding var selectedSkill: SkillLevel
    let completion: () -> Void
    @State private var page = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                ServeAILogo(compact: true)
                Spacer()
                Text("\(page + 1) / 3")
                    .font(ServeAITheme.mono(.caption, size: 10, bold: true))
                    .tracking(1)
                    .foregroundStyle(ServeAITheme.mutedInk)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)

            TabView(selection: $page) {
                intro.tag(0)
                recording.tag(1)
                skill.tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { index in
                    Capsule()
                        .fill(index == page ? ServeAITheme.brand : ServeAITheme.ink.opacity(0.18))
                        .frame(width: index == page ? 30 : 8, height: 8)
                }
            }
            .accessibilityHidden(true)
            .padding(.bottom, 18)

            Button(page == 2 ? "START ANALYZING" : "CONTINUE") {
                if page == 2 {
                    completion()
                } else {
                    withAnimation(.easeOut(duration: 0.2)) { page += 1 }
                }
            }
            .buttonStyle(ServeAIPrimaryButtonStyle())
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
        .serveAIBackground()
    }

    private var intro: some View {
        OnboardingPage(
            symbol: "figure.tennis",
            kicker: "THE FILM DOESN'T LIE",
            title: "SEE YOUR SERVE.\nOWN THE NEXT ONE.",
            message: "One clip becomes visible phases, clearly labeled video evidence, and one priority you can review before taking it back to the baseline."
        ) {
            VStack(spacing: 0) {
                OnboardingFact(symbol: "iphone.gen3", title: "On-device by default")
                Divider().overlay(ServeAITheme.separator)
                OnboardingFact(symbol: "person.crop.circle.badge.xmark", title: "No facial recognition")
                Divider().overlay(ServeAITheme.separator)
                OnboardingFact(symbol: "checkmark.seal.fill", title: "Video evidence stays separate from model validation")
            }
            .serveAISurface()
        }
    }

    private var recording: some View {
        OnboardingPage(
            symbol: "video.badge.waveform.fill",
            kicker: "GIVE THE MOTION ROOM",
            title: "FRAME THE WHOLE ATHLETE.",
            message: "Capture one complete serve from a stationary side or rear view. Better framing creates more credible feedback."
        ) {
            VStack(spacing: 10) {
                RecordingRule(number: "01", title: "FULL BODY + RACKET", detail: "Keep both feet and the full racket path visible.", color: ServeAITheme.cyan)
                RecordingRule(number: "02", title: "10–15 FEET BACK", detail: "Set the phone on a stable support.", color: ServeAITheme.orange)
                RecordingRule(number: "03", title: "BRIGHT + STILL", detail: "Use even light and never follow the player.", color: ServeAITheme.pink)
            }
        }
    }

    private var skill: some View {
        OnboardingPage(
            symbol: "scope",
            kicker: "SET THE COACHING LEVEL",
            title: "MEET THE PLAYER WHERE THEY ARE.",
            message: "The analysis stays honest; the language and drill difficulty adapt to your current game."
        ) {
            VStack(spacing: 8) {
                ForEach(SkillLevel.allCases) { level in
                    Button {
                        selectedSkill = level
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(level.title.uppercased())
                                    .font(ServeAITheme.display(.subheadline, size: 14))
                                Text(level.detail)
                                    .font(ServeAITheme.body(.caption, size: 12))
                                    .foregroundStyle(ServeAITheme.mutedInk)
                            }
                            Spacer()
                            Image(systemName: selectedSkill == level ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(selectedSkill == level ? ServeAITheme.brand : ServeAITheme.faintInk)
                        }
                        .frame(minHeight: 52)
                        .padding(.horizontal, 14)
                        .background(selectedSkill == level ? ServeAITheme.brand.opacity(0.10) : ServeAITheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(selectedSkill == level ? ServeAITheme.brand.opacity(0.38) : ServeAITheme.separator) }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selectedSkill == level ? .isSelected : [])
                }
            }
        }
    }
}

private struct OnboardingPage<Content: View>: View {
    let symbol: String
    let kicker: String
    let title: String
    let message: String
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Spacer(minLength: 26)
                ZStack {
                    Circle().fill(ServeAITheme.brand.opacity(0.11))
                    Image(systemName: symbol)
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundStyle(ServeAITheme.brand)
                }
                .frame(width: 78, height: 78)
                VStack(alignment: .leading, spacing: 10) {
                    ServeAISectionLabel(text: kicker)
                    Text(title)
                        .font(ServeAITheme.display(.largeTitle, size: 31))
                        .foregroundStyle(ServeAITheme.ink)
                        .lineSpacing(-2)
                        .minimumScaleFactor(0.72)
                    Text(message)
                        .font(ServeAITheme.body(.title3, size: 17))
                        .foregroundStyle(ServeAITheme.mutedInk)
                        .lineSpacing(3)
                }
                content
                Label("Educational coaching feedback — not a laboratory measurement.", systemImage: "info.circle")
                    .font(ServeAITheme.body(.footnote, size: 12))
                    .foregroundStyle(ServeAITheme.faintInk)
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(20)
        }
        .scrollIndicators(.hidden)
    }
}

private struct OnboardingFact: View {
    let symbol: String
    let title: String

    var body: some View {
        Label(title, systemImage: symbol)
            .font(ServeAITheme.body(.subheadline, size: 14, weight: .medium))
            .foregroundStyle(ServeAITheme.ink)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
    }
}

private struct RecordingRule: View {
    let number: String
    let title: String
    let detail: String
    let color: Color

    var body: some View {
        HStack(spacing: 14) {
            Text(number)
                .font(ServeAITheme.display(.headline, size: 16))
                .foregroundStyle(color)
                .frame(width: 42, height: 42)
                .background(color.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(ServeAITheme.display(.subheadline, size: 14))
                Text(detail)
                    .font(ServeAITheme.body(.caption, size: 12))
                    .foregroundStyle(ServeAITheme.mutedInk)
            }
            Spacer()
        }
        .padding(14)
        .background(ServeAITheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(color.opacity(0.24)) }
    }
}

#Preview { OnboardingView(selectedSkill: .constant(.intermediate), completion: {}) }
