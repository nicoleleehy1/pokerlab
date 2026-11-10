/// One of the 169 starting-hand classes (pairs, suited, offsuit), e.g. "AKs", "T9o", "77".
public struct HandClass: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let high: Rank
    public let low: Rank
    public let suited: Bool

    public init(_ a: Rank, _ b: Rank, suited: Bool) {
        high = max(a, b); low = min(a, b)
        self.suited = a == b ? false : suited
    }

    public var isPair: Bool { high == low }

    /// Grid position in the conventional 13x13 chart: row and column 0 are aces.
    /// Suited hands sit above the diagonal (row < column), offsuit below.
    public var row: Int { 12 - Int((suited || isPair ? high : low).rawValue) }
    public var column: Int { 12 - Int((suited || isPair ? low : high).rawValue) }
    /// Index 0..<169 in row-major grid order.
    public var index: Int { row * 13 + column }

    public init(row: Int, column: Int) {
        let r = Rank(rawValue: UInt8(12 - row))!, c = Rank(rawValue: UInt8(12 - column))!
        self.init(r, c, suited: row < column)
    }

    public init(index: Int) { self.init(row: index / 13, column: index % 13) }

    public static let all: [HandClass] = (0..<169).map { HandClass(index: $0) }

    /// Parses "AKs", "AKo", "QQ". (A bare "AK" is ambiguous and returns nil.)
    public init?(_ text: String) {
        let chars = Array(text)
        guard chars.count >= 2, let a = Rank(symbol: chars[0]), let b = Rank(symbol: chars[1]) else { return nil }
        if a == b { guard chars.count == 2 else { return nil }; self.init(a, b, suited: false); return }
        guard chars.count == 3 else { return nil }
        switch chars[2] {
        case "s", "S": self.init(a, b, suited: true)
        case "o", "O": self.init(a, b, suited: false)
        default: return nil
        }
    }

    public var combos: [HoleCards] {
        var result: [HoleCards] = []
        if isPair {
            for s1 in 0..<4 { for s2 in (s1 + 1)..<4 {
                result.append(HoleCards(Card(high, Suit(rawValue: UInt8(s1))!), Card(high, Suit(rawValue: UInt8(s2))!)))
            } }
        } else if suited {
            for s in Suit.allCases { result.append(HoleCards(Card(high, s), Card(low, s))) }
        } else {
            for s1 in Suit.allCases { for s2 in Suit.allCases where s1 != s2 {
                result.append(HoleCards(Card(high, s1), Card(low, s2)))
            } }
        }
        return result
    }

    /// 6 for pairs, 4 suited, 12 offsuit.
    public var comboCount: Int { isPair ? 6 : (suited ? 4 : 12) }

    public var description: String {
        isPair ? "\(high.symbol)\(low.symbol)" : "\(high.symbol)\(low.symbol)\(suited ? "s" : "o")"
    }

    /// VoiceOver text, e.g. "Ace king suited", "Pair of sevens".
    public var spokenName: String {
        if isPair { return "Pair of \(high.pluralName)" }
        let h = high.name.prefix(1).uppercased() + high.name.dropFirst()
        return "\(h) \(low.name) \(suited ? "suited" : "offsuit")"
    }

    public static func < (lhs: HandClass, rhs: HandClass) -> Bool { lhs.index < rhs.index }
}
