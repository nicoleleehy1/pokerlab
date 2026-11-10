/// Card ranks, deuce (0) through ace (12).
public enum Rank: UInt8, CaseIterable, Comparable, Sendable, Codable {
    case two = 0, three, four, five, six, seven, eight, nine, ten, jack, queen, king, ace

    public static func < (lhs: Rank, rhs: Rank) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Single-character symbol: "2"..."9", "T", "J", "Q", "K", "A".
    public var symbol: Character { Rank.symbols[Int(rawValue)] }

    public var name: String {
        ["two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
         "jack", "queen", "king", "ace"][Int(rawValue)]
    }

    public var pluralName: String { self == .six ? "sixes" : name + "s" }

    static let symbols: [Character] = ["2", "3", "4", "5", "6", "7", "8", "9", "T", "J", "Q", "K", "A"]

    public init?(symbol: Character) {
        let upper = Character(symbol.uppercased())
        guard let index = Rank.symbols.firstIndex(of: upper) else { return nil }
        self.init(rawValue: UInt8(index))
    }
}

/// Card suits. Order is arbitrary but fixed: clubs, diamonds, hearts, spades.
public enum Suit: UInt8, CaseIterable, Sendable, Codable {
    case clubs = 0, diamonds, hearts, spades

    public var symbol: Character { ["c", "d", "h", "s"][Int(rawValue)] }
    public var glyph: Character { ["♣", "♦", "♥", "♠"][Int(rawValue)] }
    public var name: String { ["clubs", "diamonds", "hearts", "spades"][Int(rawValue)] }

    public init?(symbol: Character) {
        switch symbol {
        case "c", "C", "♣": self = .clubs
        case "d", "D", "♦": self = .diamonds
        case "h", "H", "♥": self = .hearts
        case "s", "S", "♠": self = .spades
        default: return nil
        }
    }
}

/// A playing card packed into one byte: `rank * 4 + suit` (0...51).
public struct Card: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UInt8

    @inlinable public init(rawValue: UInt8) {
        precondition(rawValue < 52, "card index out of range")
        self.rawValue = rawValue
    }

    @inlinable public init(_ rank: Rank, _ suit: Suit) {
        rawValue = rank.rawValue &* 4 &+ suit.rawValue
    }

    /// Parses "As", "Td", "10h", "2c".
    public init?(_ text: some StringProtocol) {
        var chars = Array(text)
        if chars.count == 3, chars[0] == "1", chars[1] == "0" { chars = ["T", chars[2]] }
        guard chars.count == 2, let r = Rank(symbol: chars[0]), let s = Suit(symbol: chars[1]) else { return nil }
        self.init(r, s)
    }

    @inlinable public var rank: Rank { Rank(rawValue: rawValue >> 2)! }
    @inlinable public var suit: Suit { Suit(rawValue: rawValue & 3)! }

    /// Bit position in a `CardSet`: each suit owns a 16-bit lane, rank is the offset in the lane.
    @inlinable public var bitIndex: Int { Int(rawValue & 3) &* 16 &+ Int(rawValue >> 2) }
    @inlinable public var mask: UInt64 { 1 &<< UInt64(bitIndex) }

    public var description: String { "\(rank.symbol)\(suit.symbol)" }

    /// VoiceOver-friendly name, e.g. "Ace of spades".
    public var spokenName: String {
        let r = rank.name
        return r.prefix(1).uppercased() + r.dropFirst() + " of " + suit.name
    }

    public static func < (lhs: Card, rhs: Card) -> Bool { lhs.rawValue < rhs.rawValue }

    /// All 52 cards in index order.
    public static let all: [Card] = (0..<52).map { Card(rawValue: UInt8($0)) }
}

/// A set of cards as a 64-bit mask. Suit `s` occupies bits `16*s ..< 16*s + 13`,
/// so suit lanes can be extracted with a shift, which makes flush detection a popcount.
public struct CardSet: Hashable, Sendable, Codable, Sequence, CustomStringConvertible {
    public var rawValue: UInt64

    @inlinable public init(rawValue: UInt64) { self.rawValue = rawValue }
    @inlinable public init() { rawValue = 0 }
    @inlinable public init<S: Sequence>(_ cards: S) where S.Element == Card {
        var m: UInt64 = 0
        for c in cards { m |= c.mask }
        rawValue = m
    }

    /// Parses "AsKd", "As Kd Qh", "As,Kd". Returns nil on invalid card or duplicates.
    public init?(parsing text: String) {
        let cleaned = text.filter { !$0.isWhitespace && $0 != "," }
        var chars = Array(cleaned)
        var cards: [Card] = []
        var i = 0
        while i < chars.count {
            if chars[i] == "1", i + 2 < chars.count, chars[i + 1] == "0" {
                chars[i + 1] = "T"; i += 1
            }
            guard i + 1 < chars.count, let card = Card(String(chars[i...i + 1])) else { return nil }
            cards.append(card)
            i += 2
        }
        let set = CardSet(cards)
        guard set.count == cards.count else { return nil }
        self = set
    }

    public static let fullDeck = CardSet(Card.all)
    /// Mask of every valid bit (the 52 card positions).
    public static let validBits: UInt64 = 0x1FFF_1FFF_1FFF_1FFF

    @inlinable public var count: Int { rawValue.nonzeroBitCount }
    @inlinable public var isEmpty: Bool { rawValue == 0 }
    @inlinable public func contains(_ card: Card) -> Bool { rawValue & card.mask != 0 }
    @inlinable public func intersects(_ other: CardSet) -> Bool { rawValue & other.rawValue != 0 }
    @inlinable public mutating func insert(_ card: Card) { rawValue |= card.mask }
    @inlinable public mutating func remove(_ card: Card) { rawValue &= ~card.mask }
    @inlinable public func union(_ other: CardSet) -> CardSet { CardSet(rawValue: rawValue | other.rawValue) }
    @inlinable public func subtracting(_ other: CardSet) -> CardSet { CardSet(rawValue: rawValue & ~other.rawValue) }
    @inlinable public var complement: CardSet { CardSet(rawValue: ~rawValue & CardSet.validBits) }

    /// The 13-bit rank mask of one suit.
    @inlinable public func lane(_ suit: Suit) -> UInt16 {
        UInt16(truncatingIfNeeded: rawValue >> (UInt64(suit.rawValue) * 16)) & 0x1FFF
    }

    public struct Iterator: IteratorProtocol {
        var remaining: UInt64
        public mutating func next() -> Card? {
            guard remaining != 0 else { return nil }
            let bit = remaining.trailingZeroBitCount
            remaining &= remaining &- 1
            return Card(Rank(rawValue: UInt8(bit & 15))!, Suit(rawValue: UInt8(bit >> 4))!)
        }
    }

    public func makeIterator() -> Iterator { Iterator(remaining: rawValue) }

    /// Cards sorted high rank first, for display.
    public var sortedForDisplay: [Card] {
        sorted { $0.rank != $1.rank ? $0.rank > $1.rank : $0.suit.rawValue > $1.suit.rawValue }
    }

    public var description: String { sortedForDisplay.map(\.description).joined() }
}

/// Two hole cards. Stored ordered (higher card first) so equal hands compare equal.
public struct HoleCards: Hashable, Sendable, Codable, CustomStringConvertible {
    public let high: Card
    public let low: Card

    public init(_ a: Card, _ b: Card) {
        precondition(a != b, "hole cards must differ")
        if a.rank > b.rank || (a.rank == b.rank && a.suit.rawValue > b.suit.rawValue) {
            high = a; low = b
        } else {
            high = b; low = a
        }
    }

    public init?(_ text: String) {
        guard let set = CardSet(parsing: text), set.count == 2 else { return nil }
        let cards = Array(set)
        self.init(cards[0], cards[1])
    }

    @inlinable public var mask: UInt64 { high.mask | low.mask }
    public var cardSet: CardSet { CardSet(rawValue: mask) }
    public var handClass: HandClass { HandClass(high.rank, low.rank, suited: high.suit == low.suit) }
    public var description: String { "\(high)\(low)" }
}
