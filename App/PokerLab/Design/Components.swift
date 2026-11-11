import SwiftUI

/// Full-width primary button. Its height is fixed at 52 pt (more only for accessibility text
/// sizes), so it never jumps when the label changes from "Check" to "Next question".
struct PrimaryButtonStyle: ButtonStyle {
    var height: CGFloat = 52
    var fullWidth = true
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.dynamicTypeSize) private var typeSize

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.label)
            .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
            .padding(.horizontal, 16)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .frame(height: typeSize.isAccessibilitySize ? nil : height)
            .frame(minHeight: height)
            .foregroundStyle(isEnabled ? Theme.onInk : Theme.faint)
            .background(isEnabled ? Theme.ink : Theme.subtle, in: .rect(cornerRadius: fullWidth ? Theme.controlRadius : 8))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .contentShape(.rect)
    }
}

/// Outlined secondary button (Reset, pills).
struct OutlineButtonStyle: ButtonStyle {
    var height: CGFloat = 36
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.footnote, weight: .medium))
            .padding(.horizontal, 12)
            .frame(minHeight: height)
            .foregroundStyle(isEnabled ? Theme.ink : Theme.faint)
            .background(configuration.isPressed ? Theme.subtle : Theme.background, in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border, lineWidth: 1))
            .contentShape(.rect)
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
    static var compactPrimary: PrimaryButtonStyle { PrimaryButtonStyle(height: 40, fullWidth: false) }
}

extension ButtonStyle where Self == OutlineButtonStyle {
    static var outline: OutlineButtonStyle { OutlineButtonStyle() }
}

/// 6 pt progress track with an ink fill.
struct ProgressTrack: View {
    let value: Double
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.subtle)
                Capsule().fill(Theme.ink).frame(width: geo.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: height)
        .motionAware(value)
        .accessibilityElement()
        .accessibilityValue(Theme.percent(value, digits: 0))
    }
}

/// Rounded pill with a line icon, e.g. the streak counter.
struct Pill: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(.footnote, weight: .regular)).accessibilityHidden(true)
            Text(text).font(Theme.label).monospacedDigit()
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 36)
        .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

/// Title block used at the top of each root tab.
struct ScreenHeader<Trailing: View>: View {
    var overline: String?
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                if let overline { Text(overline).font(Theme.caption).foregroundStyle(Theme.muted) }
                Text(title).font(Theme.screenTitle).tracking(-0.5).accessibilityAddTraits(.isHeader)
            }
            Spacer(minLength: 12)
            trailing
        }
    }
}

extension ScreenHeader where Trailing == EmptyView {
    init(overline: String? = nil, title: String) {
        self.init(overline: overline, title: title) { EmptyView() }
    }
}

/// Row inside a bordered list: line icon, title, optional subtitle, chevron.
struct ListRow: View {
    let symbol: String
    let title: String
    var subtitle: String?
    var showsChevron = true

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(.body, weight: .regular))
                .frame(width: 28)
                .foregroundStyle(Theme.ink)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.label).foregroundStyle(Theme.ink)
                if let subtitle { Text(subtitle).font(Theme.caption).foregroundStyle(Theme.muted) }
            }
            Spacer(minLength: 8)
            if showsChevron {
                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(Theme.faint).accessibilityHidden(true)
            }
        }
        .padding(.vertical, 14)
        .contentShape(.rect)
    }
}

/// Vertical stack of rows separated by hairlines, inside a bordered card.
struct RowGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content) { subviews in
                ForEach(subviews.indices, id: \.self) { i in
                    subviews[i]
                    if i < subviews.count - 1 { Rectangle().fill(Theme.subtle).frame(height: 1) }
                }
            }
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border, lineWidth: 1))
    }
}

/// A labelled number for stat rows.
struct StatTile: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(Theme.mediumNumber).contentTransition(.numericText()).minimumScaleFactor(0.6).lineLimit(1)
            Text(title).font(Theme.caption).foregroundStyle(Theme.muted).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

/// Feedback panel shown after checking an answer.
struct FeedbackPanel: View {
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(.subheadline, weight: .semibold))
            Text(message).font(Theme.caption).foregroundStyle(Theme.body).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.wash, in: .rect(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}
