import SwiftUI
import PokerCore

/// Visual language: system backgrounds, the app tint for the hero, a neutral grey for the
/// villain, rounded monospaced digits for every number that animates.
enum Theme {
    static let hero = Color.accentColor
    static let villain = Color(.systemGray)
    static let tie = Color(.systemGray3)

    static var bigNumber: Font { .system(.largeTitle, design: .rounded, weight: .semibold).monospacedDigit() }
    static var mediumNumber: Font { .system(.title2, design: .rounded, weight: .semibold).monospacedDigit() }
    static var smallNumber: Font { .system(.subheadline, design: .rounded, weight: .medium).monospacedDigit() }

    static func percent(_ x: Double, digits: Int = 1) -> String {
        x.formatted(.percent.precision(.fractionLength(digits)))
    }
}

extension Suit {
    /// Two-colour (red/black) or four-colour deck. Suit glyphs are always drawn too, so colour
    /// is never the only cue.
    func color(fourColor: Bool) -> Color {
        switch self {
        case .spades: .primary
        case .hearts: .red
        case .diamonds: fourColor ? .blue : .red
        case .clubs: fourColor ? .green : .primary
        }
    }
}

extension Rank {
    var displaySymbol: String { self == .ten ? "10" : String(symbol) }
}

/// Animation helper honouring Reduce Motion: springs become short cross-fades.
struct MotionAware: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let value: AnyHashable
    func body(content: Content) -> some View {
        content.animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.35, dampingFraction: 0.8), value: value)
    }
}

extension View {
    func motionAware(_ value: some Hashable) -> some View { modifier(MotionAware(value: AnyHashable(value))) }

    /// Rounded, grouped "card" container used across screens.
    func panel() -> some View {
        padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
    }
}
