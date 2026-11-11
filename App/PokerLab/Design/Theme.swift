import SwiftUI
import PokerCore

/// Visual language from docs/design: a monochrome zinc palette, 1 pt borders, 8-12 pt radii,
/// 24 pt side padding and line icons. Every token has a dark-mode counterpart and a darker
/// variant for Increase Contrast. Numbers use tabular digits so they don't jitter as they change.
enum Theme {
    // MARK: Colour tokens (light hex, dark hex)

    /// zinc-950: text, primary buttons, filled progress.
    static let ink = Color(light: 0x09090B, dark: 0xFAFAFA)
    /// Text on an ink background.
    static let onInk = Color(light: 0xFAFAFA, dark: 0x09090B)
    /// zinc-500: secondary text.
    static let muted = Color(light: 0x71717A, dark: 0xA1A1AA, highContrastLight: 0x52525B, highContrastDark: 0xD4D4D8)
    /// zinc-600: body copy inside feedback panels.
    static let body = Color(light: 0x52525B, dark: 0xD4D4D8, highContrastLight: 0x3F3F46, highContrastDark: 0xE4E4E7)
    /// zinc-400: placeholders, locked items, inactive tab icons.
    static let faint = Color(light: 0xA1A1AA, dark: 0x71717A, highContrastLight: 0x71717A, highContrastDark: 0xA1A1AA)
    /// zinc-200: 1 pt borders.
    static let border = Color(light: 0xE4E4E7, dark: 0x27272A, highContrastLight: 0xA1A1AA, highContrastDark: 0x71717A)
    /// zinc-300: dashed placeholders, tie segment.
    static let strongBorder = Color(light: 0xD4D4D8, dark: 0x3F3F46)
    /// zinc-100: tracks, selected fills, disabled buttons.
    static let subtle = Color(light: 0xF4F4F5, dark: 0x18181B)
    /// zinc-50: feedback panels.
    static let wash = Color(light: 0xFAFAFA, dark: 0x111113)
    static let background = Color(light: 0xFFFFFF, dark: 0x09090B)
    /// red-700: red suits and the rare destructive state.
    static let red = Color(light: 0xB91C1C, dark: 0xF87171)
    static let blue = Color(light: 0x1D4ED8, dark: 0x60A5FA)
    static let green = Color(light: 0x15803D, dark: 0x4ADE80)

    // Semantic aliases used by charts and equity bars.
    static let hero = ink
    static let villain = border
    static let tie = strongBorder

    // MARK: Metrics

    static let sidePadding: CGFloat = 24
    static let cardRadius: CGFloat = 12
    static let controlRadius: CGFloat = 10
    static let sectionSpacing: CGFloat = 32

    // MARK: Type (text styles, so everything follows Dynamic Type)

    static var screenTitle: Font { .system(.title, weight: .semibold) }
    static var questionTitle: Font { .system(.title2, weight: .semibold) }
    static var sectionTitle: Font { .system(.title3, weight: .semibold) }
    static var label: Font { .system(.subheadline, weight: .medium) }
    static var caption: Font { .footnote }
    static var eyebrow: Font { .system(.caption, weight: .medium) }

    static var bigNumber: Font { .system(.title, weight: .semibold).monospacedDigit() }
    static var mediumNumber: Font { .system(.title3, weight: .semibold).monospacedDigit() }
    static var smallNumber: Font { .system(.footnote, weight: .medium).monospacedDigit() }

    static func percent(_ x: Double, digits: Int = 1) -> String {
        x.formatted(.percent.precision(.fractionLength(digits)))
    }
}

extension Color {
    /// A colour that follows light/dark mode and Increase Contrast.
    init(light: UInt32, dark: UInt32, highContrastLight: UInt32? = nil, highContrastDark: UInt32? = nil) {
        self.init(uiColor: UIColor { traits in
            let high = traits.accessibilityContrast == .high
            let isDark = traits.userInterfaceStyle == .dark
            let hex = isDark ? (high ? highContrastDark ?? dark : dark) : (high ? highContrastLight ?? light : light)
            return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

extension Suit {
    /// Two-colour (ink/red) or four-colour deck. Suit glyphs are always drawn too, so colour
    /// is never the only cue.
    func color(fourColor: Bool) -> Color {
        switch self {
        case .spades: Theme.ink
        case .hearts: Theme.red
        case .diamonds: fourColor ? Theme.blue : Theme.red
        case .clubs: fourColor ? Theme.green : Theme.ink
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

    /// Bordered card: 1 pt zinc-200 border, 12 pt radius, 20 pt padding.
    func panel(padding: CGFloat = 20) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.background, in: .rect(cornerRadius: Theme.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border, lineWidth: 1))
    }

    /// Small uppercase label above a heading ("UNIT 2").
    func eyebrowStyle() -> some View {
        font(Theme.eyebrow).tracking(0.7).textCase(.uppercase).foregroundStyle(Theme.muted)
    }

    /// Root-screen background and side padding.
    func screenPadding() -> some View {
        padding(.horizontal, Theme.sidePadding)
    }
}
