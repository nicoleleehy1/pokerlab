import PokerCore

/// One detection from the object-detection model in one frame.
public struct CardDetection: Hashable, Sendable {
    public let card: Card
    public let confidence: Float
    /// Normalised bounding box (Vision coordinates: origin bottom-left, 0...1).
    public let x: Double, y: Double, width: Double, height: Double

    public init(card: Card, confidence: Float, x: Double = 0, y: Double = 0, width: Double = 0, height: Double = 0) {
        self.card = card; self.confidence = confidence
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

/// Maps model class labels to cards. Accepts the common naming schemes used by public card
/// datasets and Create ML projects: "As", "AS", "10h", "Th", "ace_of_spades", "10_hearts".
public enum CardLabel {
    public static func card(from label: String) -> Card? {
        let trimmed = label.trimmingWhitespace()
        if let c = Card(trimmed) { return c }
        let lower = trimmed.lowercased()
        if lower.count == 2 || lower.count == 3, let c = Card(String(lower.dropLast()).uppercased() + String(lower.last!)) {
            return c
        }
        let words = lower.split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == " " }).filter { $0 != "of" }
        guard words.count == 2 else { return nil }
        let rankWords: [String: Rank] = [
            "ace": .ace, "king": .king, "queen": .queen, "jack": .jack, "ten": .ten, "10": .ten, "9": .nine,
            "nine": .nine, "8": .eight, "eight": .eight, "7": .seven, "seven": .seven, "6": .six, "six": .six,
            "5": .five, "five": .five, "4": .four, "four": .four, "3": .three, "three": .three, "2": .two, "two": .two,
            "a": .ace, "k": .king, "q": .queen, "j": .jack, "t": .ten,
        ]
        let suitWords: [String: Suit] = ["spades": .spades, "spade": .spades, "hearts": .hearts, "heart": .hearts,
                                         "diamonds": .diamonds, "diamond": .diamonds, "clubs": .clubs, "club": .clubs]
        guard let r = rankWords[String(words[0])], let s = suitWords[String(words[1])] else { return nil }
        return Card(r, s)
    }
}

/// Stabilises noisy per-frame detections. A card is *confirmed* once it has been seen with
/// enough confidence in at least `minimumHits` of the last `window` frames, and *dropped*
/// when it falls below `releaseHits` (hysteresis, so a card does not flicker at the threshold).
public struct FrameDebouncer: Sendable {
    public let window: Int
    public let minimumHits: Int
    public let releaseHits: Int
    public let minimumConfidence: Float

    private var frames: [Set<Card>] = []
    public private(set) var confirmed: Set<Card> = []

    public init(window: Int = 8, minimumHits: Int = 5, releaseHits: Int = 2, minimumConfidence: Float = 0.6) {
        precondition(minimumHits <= window && releaseHits < minimumHits)
        self.window = window; self.minimumHits = minimumHits
        self.releaseHits = releaseHits; self.minimumConfidence = minimumConfidence
    }

    /// Feeds one frame; returns the confirmed set after it.
    @discardableResult
    public mutating func ingest(_ detections: [CardDetection]) -> Set<Card> {
        // Keep the best detection per card; a physical card can only be one card.
        let seen = Set(detections.filter { $0.confidence >= minimumConfidence }.map(\.card))
        frames.append(seen)
        if frames.count > window { frames.removeFirst(frames.count - window) }
        var counts: [Card: Int] = [:]
        for f in frames { for c in f { counts[c, default: 0] += 1 } }
        var next = confirmed.filter { (counts[$0] ?? 0) >= releaseHits }
        for (card, n) in counts where n >= minimumHits { next.insert(card) }
        confirmed = next
        return confirmed
    }

    public mutating func reset() { frames.removeAll(); confirmed.removeAll() }
}

/// Splits confirmed cards into hero hole cards and board by position: cards in the lower
/// part of the frame (nearest the camera) are the hero's hand, the rest are the board.
public enum TableLayout {
    public static func split(_ detections: [CardDetection], confirmed: Set<Card>, heroBelow: Double = 0.33) -> (hero: [Card], board: [Card]) {
        var best: [Card: CardDetection] = [:]
        for d in detections where confirmed.contains(d.card) {
            if best[d.card].map({ $0.confidence < d.confidence }) ?? true { best[d.card] = d }
        }
        let placed = best.values.sorted { $0.x < $1.x }
        let hero = placed.filter { $0.y + $0.height / 2 < heroBelow }.map(\.card)
        let board = placed.filter { $0.y + $0.height / 2 >= heroBelow }.map(\.card)
        return (Array(hero.prefix(2)), Array(board.prefix(5)))
    }
}

extension String {
    func trimmingWhitespace() -> String {
        var s = Substring(self)
        while s.first?.isWhitespace == true { s = s.dropFirst() }
        while s.last?.isWhitespace == true { s = s.dropLast() }
        return String(s)
    }
}
