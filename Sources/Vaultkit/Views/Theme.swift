import SwiftUI

/// Vaultkit's design language, lifted token-for-token from Auger
/// (auger.tugane.com) — the house style: committed dark, elevated cards on
/// #1c1c1e, hairline borders, deep soft shadows, Apple-dark accent + semantics.
enum Theme {
    // surfaces
    static let bg       = Color(hex: 0x1c1c1e)
    static let bg2      = Color(hex: 0x161618)
    static let rail     = Color(hex: 0x242426)   // sidebar
    static let card     = Color(hex: 0x2c2c2e)
    static let cardHover = Color(hex: 0x333335)

    // accent + semantics (Apple dark system colors, as Auger uses them)
    static let accent   = Color(hex: 0x0a84ff)
    static let green    = Color(hex: 0x30d158)
    static let red      = Color(hex: 0xff453a)
    static let amber    = Color(hex: 0xffd60a)
    static let teal     = Color(hex: 0x64d2ff)
    static let purple   = Color(hex: 0xbf5af2)

    // labels & lines
    static let label2   = Color.white.opacity(0.66)
    static let label3   = Color.white.opacity(0.56)
    static let sep      = Color.white.opacity(0.09)
    static let cardBorder = Color.white.opacity(0.055)
    static let chipFill = Color.white.opacity(0.11)

    // radii
    static let radiusSM: CGFloat = 9
    static let radius: CGFloat = 12
    static let radiusLG: CGFloat = 16
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255
        )
    }
}

/// Auger-style elevated card: #2c2c2e, 16pt continuous corners, hairline
/// border, deep soft shadow.
struct AugerCard: ViewModifier {
    var hovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusLG, style: .continuous)
                    .fill(hovering ? Theme.cardHover : Theme.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.radiusLG, style: .continuous)
                            .strokeBorder(Theme.cardBorder, lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.30), radius: 15, y: 5)
            )
    }
}

extension View {
    func cardStyle(hovering: Bool = false) -> some View {
        modifier(AugerCard(hovering: hovering))
    }
}
