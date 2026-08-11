import SwiftUI

enum YJColor {
    static let ink = Color(red: 0.082, green: 0.086, blue: 0.11)
    static let paper = Color(red: 0.957, green: 0.941, blue: 0.91)
    static let card = Color(red: 0.997, green: 0.989, blue: 0.969)
    static let purple = Color(red: 0.42, green: 0.33, blue: 1)
    static let lime = Color(red: 0.84, green: 0.965, blue: 0.31)
    static let coral = Color(red: 1, green: 0.37, blue: 0.34)
    static let muted = Color(red: 0.45, green: 0.46, blue: 0.44)
    static let line = Color.black.opacity(0.1)
}

struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(YJColor.card)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(YJColor.line))
            .shadow(color: YJColor.ink.opacity(0.045), radius: 14, y: 7)
    }
}

extension View {
    func youjiCard() -> some View { modifier(CardStyle()) }

    func heroCard(colors: [Color]) -> some View {
        padding(18)
            .background(
                LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 24, style: .continuous)
            )
            .shadow(color: colors.last?.opacity(0.18) ?? .clear, radius: 18, y: 9)
    }
}
