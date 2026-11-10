/// A slow, obviously-correct evaluator: it scores every 5-card subset and keeps the best.
/// Used as the oracle the fast evaluator is tested against.
public enum ReferenceEvaluator {
    /// Strength code of exactly five cards.
    public static func strength5(_ cards: [Card]) -> UInt32 {
        precondition(cards.count == 5)
        let ranks = cards.map { Int($0.rank.rawValue) }
        let isFlush = Set(cards.map(\.suit)).count == 1
        var counts: [Int: Int] = [:]
        for r in ranks { counts[r, default: 0] += 1 }
        // Groups ordered by size, then rank: e.g. full house KKK44 -> [K, 4].
        let groups = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key > $1.key }
        let shape = groups.map(\.value)
        let ordered = groups.map(\.key)

        let distinct = Set(ranks).sorted(by: >)
        var straightTop: Int?
        if distinct.count == 5 {
            if distinct[0] - distinct[4] == 4 { straightTop = distinct[0] }
            if distinct == [12, 3, 2, 1, 0] { straightTop = 3 }
        }

        if let top = straightTop, isFlush { return StrengthCode.make(.straightFlush, [top]) }
        if shape == [4, 1] { return StrengthCode.make(.quads, ordered) }
        if shape == [3, 2] { return StrengthCode.make(.fullHouse, ordered) }
        if isFlush { return StrengthCode.make(.flush, distinct) }
        if let top = straightTop { return StrengthCode.make(.straight, [top]) }
        if shape == [3, 1, 1] { return StrengthCode.make(.trips, ordered) }
        if shape == [2, 2, 1] { return StrengthCode.make(.twoPair, ordered) }
        if shape == [2, 1, 1, 1] { return StrengthCode.make(.pair, ordered) }
        return StrengthCode.make(.highCard, distinct)
    }

    /// Best strength code over all 5-card subsets of 5...7 cards.
    public static func strength(_ cards: [Card]) -> UInt32 {
        precondition((5...7).contains(cards.count))
        var best: UInt32 = 0
        let n = cards.count
        for a in 0..<n { for b in (a + 1)..<n { for c in (b + 1)..<n { for d in (c + 1)..<n { for e in (d + 1)..<n {
            best = max(best, strength5([cards[a], cards[b], cards[c], cards[d], cards[e]]))
        } } } } }
        return best
    }

    public static func evaluate(_ cards: [Card]) -> HandRank {
        EvaluatorTables.shared.handRank(forStrength: strength(cards))
    }
}
