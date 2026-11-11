import SwiftUI
import PokerCore

/// A playing card drawn entirely in SwiftUI (no image assets): crisp at any size, follows
/// Dynamic Type and the four-colour deck setting, and reads as "Ace of spades" in VoiceOver.
struct CardView: View {
    let card: Card?
    var baseWidth: CGFloat = 46
    var placeholder = "Add card"

    @ScaledMetric(relativeTo: .title) private var scale: CGFloat = 1
    @AppStorage("fourColorDeck") private var fourColorPreference = false
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    private var width: CGFloat { min(baseWidth * scale, baseWidth * 2) }
    private var fourColor: Bool { fourColorPreference || differentiateWithoutColor }
    private var radius: CGFloat { width * 0.17 }

    var body: some View {
        ZStack {
            if let card {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Theme.background)
                    .shadow(color: .black.opacity(0.04), radius: 1, y: 1)
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: 1)
                VStack(spacing: width * 0.04) {
                    Text(card.rank.displaySymbol)
                        .font(.system(size: width * (card.rank == .ten ? 0.36 : 0.42), weight: .semibold))
                    Text(String(card.suit.glyph))
                        .font(.system(size: width * 0.34))
                }
                .foregroundStyle(card.suit.color(fourColor: fourColor))
                .minimumScaleFactor(0.5)
            } else {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(Theme.strongBorder)
                Image(systemName: "plus")
                    .font(.system(size: width * 0.28, weight: .regular))
                    .foregroundStyle(Theme.faint)
            }
        }
        .frame(width: width, height: width * 1.375)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(card?.spokenName ?? placeholder)
    }
}

/// A row of card slots that opens the picker when tapped.
struct CardSlotsRow: View {
    let cards: [Card?]
    let label: String
    var baseWidth: CGFloat = 46
    var spacing: CGFloat = 6
    var onTap: (Int) -> Void

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(cards.indices, id: \.self) { i in
                Button { onTap(i) } label: {
                    CardView(card: cards[i], baseWidth: baseWidth, placeholder: "\(label) card \(i + 1), empty")
                }
                .buttonStyle(.plain)
                .accessibilityHint(cards[i] == nil ? "Double-tap to choose a card" : "Double-tap to change this card")
                .accessibilityIdentifier("\(label)-slot-\(i)")
            }
        }
        .motionAware(cards)
    }
}

/// Picker sheet: 4 suits x 13 ranks, cards already in use are disabled.
struct CardPickerSheet: View {
    let title: String
    let used: CardSet
    var current: Card?
    var onPick: (Card?) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @AppStorage("fourColorDeck") private var fourColorPreference = false
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @State private var picked = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Suit.allCases.reversed(), id: \.self) { suit in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(suit.name.capitalized).font(.headline).accessibilityAddTraits(.isHeader)
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: typeSize.isAccessibilitySize ? 5 : 13), spacing: 4) {
                                ForEach(Rank.allCases.reversed(), id: \.self) { rank in
                                    cell(Card(rank, suit))
                                }
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                if current != nil {
                    ToolbarItem(placement: .destructiveAction) {
                        Button("Remove", role: .destructive) { onPick(nil); dismiss() }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .sensoryFeedback(.selection, trigger: picked)
    }

    private func cell(_ card: Card) -> some View {
        let disabled = used.contains(card) && card != current
        let fourColor = fourColorPreference || differentiateWithoutColor
        return Button {
            picked += 1
            onPick(card)
            dismiss()
        } label: {
            VStack(spacing: 0) {
                Text(card.rank.displaySymbol).font(.system(.callout, weight: .semibold))
                Text(String(card.suit.glyph)).font(.caption)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(disabled ? Theme.faint.opacity(0.5) : card.suit.color(fourColor: fourColor))
            .background(card == current ? Theme.subtle : Theme.background, in: .rect(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(card == current ? Theme.ink : Theme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(card.spokenName)
        .accessibilityValue(disabled ? "In use" : (card == current ? "Selected" : ""))
        .accessibilityIdentifier("pick-\(card)")
    }
}
