import SwiftUI

/// Midnight Archive: quiet surfaces let game art and platform colors lead.
enum YJColor {
    static let paper = Color(red: 0.035, green: 0.051, blue: 0.055)
    static let card = Color(red: 0.075, green: 0.094, blue: 0.098)
    static let elevated = Color(red: 0.11, green: 0.13, blue: 0.14)
    static let ink = Color(red: 0.94, green: 0.96, blue: 0.93)
    static let muted = Color(red: 0.58, green: 0.65, blue: 0.63)
    static let lime = Color(red: 0.83, green: 0.96, blue: 0.42)
    static let purple = Color(red: 0.68, green: 0.64, blue: 1)
    static let coral = Color(red: 1, green: 0.40, blue: 0.39)
    static let playStation = Color(red: 0.35, green: 0.64, blue: 1)
    static let nintendo = Color(red: 1, green: 0.36, blue: 0.39)
    static let line = Color.white.opacity(0.09)

    static func platform(_ platform: GamePlatform) -> Color {
        platform == .playStation ? playStation : nintendo
    }
}

struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(YJColor.card)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(YJColor.line))
    }
}

struct YJBackground: View {
    var body: some View {
        LinearGradient(
            colors: [Color(red: 0.065, green: 0.10, blue: 0.10), YJColor.paper, YJColor.paper],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}

struct YJPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.bold())
            .foregroundStyle(isEnabled ? YJColor.paper : YJColor.muted)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(isEnabled ? YJColor.lime : YJColor.elevated,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

struct PlatformBadge: View {
    let platform: GamePlatform
    var body: some View {
        Text(platform.shortName)
            .font(.system(.caption2, design: .monospaced, weight: .heavy))
            .foregroundStyle(YJColor.platform(platform))
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(YJColor.platform(platform).opacity(0.13), in: RoundedRectangle(cornerRadius: 6))
            .accessibilityLabel(platform.rawValue)
    }
}

struct PlatinumBadge: View {
    var body: some View {
        Label("已白金", systemImage: "trophy.fill")
            .font(.caption2.bold())
            .foregroundStyle(Color(red: 0.78, green: 0.91, blue: 1))
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Color(red: 0.15, green: 0.26, blue: 0.34), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.16)))
    }
}

/// Artwork stays decorative; all copy remains native, scalable and accessible.
struct YJArtwork: View {
    let name: String
    var shade: Double = 0.2

    var body: some View {
        GeometryReader { proxy in
            Image(name)
                .resizable().scaledToFill()
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
                .overlay(Color.black.opacity(shade))
                .overlay(LinearGradient(colors: [.clear, YJColor.card], startPoint: .center, endPoint: .bottom))
        }
        .accessibilityHidden(true)
    }
}

struct YJFeatureHeading: View {
    let eyebrow: String
    let title: String
    let subtitle: String
    var artwork = "ArchiveWorld"
    var accent = YJColor.lime

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(eyebrow)
                .font(.system(.caption2, design: .monospaced, weight: .bold))
                .tracking(2).foregroundStyle(accent)
            Text(title).font(.system(.title, design: .rounded, weight: .bold))
                .foregroundStyle(YJColor.ink)
            Text(subtitle).font(.subheadline).foregroundStyle(YJColor.ink.opacity(0.72))
                .lineSpacing(4)
        }
        .frame(maxWidth: .infinity, minHeight: 180, alignment: .leading)
        .padding(22)
        .background(YJArtwork(name: artwork, shade: 0.32))
        .youjiCard()
    }
}

extension View {
    func youjiCard() -> some View { modifier(CardStyle()) }

    func heroCard(colors: [Color]) -> some View {
        padding(20)
            .background(
                LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 22, style: .continuous)
            )
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Color.white.opacity(0.12)))
    }
}

/// Keep AI paragraphs readable while supporting inline emphasis in native Text.
enum YJText {
    static func markdown(_ source: String) -> AttributedString {
        let normalized = source.components(separatedBy: "\n").map { line in
            let hashes = line.prefix { $0 == "#" }.count
            let remainder = line.dropFirst(hashes)
            if (1...6).contains(hashes), remainder.first == " " {
                return "**\(remainder.trimmingCharacters(in: .whitespaces))**"
            }
            return line
        }.joined(separator: "\n")
        return (try? AttributedString(markdown: normalized,
                    options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(source)
    }
}
