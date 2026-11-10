/// A weighted set of hole-card combinations, e.g. parsed from "AKs, QQ+, A5s-A2s".
public struct HandRange: Hashable, Sendable, Codable, CustomStringConvertible {
    public struct Combo: Hashable, Sendable, Codable {
        public let cards: HoleCards
        public let weight: Double
        public init(_ cards: HoleCards, weight: Double = 1) { self.cards = cards; self.weight = weight }
    }

    /// At most one entry per distinct combo.
    public private(set) var combos: [Combo]

    public init(combos: [Combo]) {
        var seen: [HoleCards: Int] = [:]
        var result: [Combo] = []
        for c in combos where c.weight > 0 {
            if let i = seen[c.cards] { result[i] = c } else { seen[c.cards] = result.count; result.append(c) }
        }
        // Canonical order (strongest grid position first) so equal ranges compare equal.
        self.combos = result.sorted {
            $0.cards.high != $1.cards.high ? $0.cards.high > $1.cards.high : $0.cards.low > $1.cards.low
        }
    }

    public init(_ hand: HoleCards) { self.init(combos: [Combo(hand)]) }

    public init(classes: some Sequence<HandClass>, weight: Double = 1) {
        self.init(combos: classes.flatMap { $0.combos.map { Combo($0, weight: weight) } })
    }

    /// Parses range notation; throws `RangeParseError` on bad input.
    public init(_ notation: String) throws { self = try RangeParser.parse(notation) }

    public static let all = HandRange(classes: HandClass.all)

    public var isEmpty: Bool { combos.isEmpty }
    public var comboCount: Int { combos.count }
    public var totalWeight: Double { combos.reduce(0) { $0 + $1.weight } }

    /// The single combo if this range is exactly one hand at full weight.
    public var singleHand: HoleCards? { combos.count == 1 ? combos[0].cards : nil }

    /// Fraction of all 1,326 combos (weighted), e.g. 0.15 for a 15% range.
    public var fractionOfAllHands: Double { totalWeight / 1326 }

    /// Card removal: drops combos that use any card in `dead` (board, other known hands).
    public func removing(_ dead: CardSet) -> HandRange {
        var r = self
        r.combos = combos.filter { $0.cards.mask & dead.rawValue == 0 }
        return r
    }

    /// Weight of each of the 169 classes, from 0 (absent) to 1 (all combos at full weight).
    public var classWeights: [Double] {
        var w = [Double](repeating: 0, count: 169)
        for c in combos {
            let hc = c.cards.handClass
            w[hc.index] += c.weight / Double(hc.comboCount)
        }
        return w
    }

    /// Compact notation by class: full classes as "AKs", partial combos listed individually.
    public var description: String {
        var byClass: [HandClass: [Combo]] = [:]
        for c in combos { byClass[c.cards.handClass, default: []].append(c) }
        var parts: [String] = []
        for hc in HandClass.all {
            guard let cs = byClass[hc] else { continue }
            if cs.count == hc.comboCount, Set(cs.map(\.weight)).count == 1 {
                let w = cs[0].weight
                parts.append(w == 1 ? hc.description : "\(hc.description):\(w)")
            } else {
                parts.append(contentsOf: cs.map { $0.weight == 1 ? $0.cards.description : "\($0.cards.description):\($0.weight)" })
            }
        }
        return parts.joined(separator: ", ")
    }
}
