/// The nine hand categories, weakest to strongest.
public enum HandCategory: Int, CaseIterable, Comparable, Sendable, Codable {
    case highCard = 0, pair, twoPair, trips, straight, flush, fullHouse, quads, straightFlush

    public static func < (lhs: HandCategory, rhs: HandCategory) -> Bool { lhs.rawValue < rhs.rawValue }

    public var name: String {
        ["High card", "Pair", "Two pair", "Three of a kind", "Straight", "Flush",
         "Full house", "Four of a kind", "Straight flush"][rawValue]
    }

    /// Number of distinct 5-card equivalence classes in each category (sums to 7462).
    public static let classCounts = [1277, 2860, 858, 858, 10, 1277, 156, 156, 10]
}

/// Strength of a 5- to 7-card hand as its ordinal among the 7,462 distinct
/// 5-card equivalence classes: 1 is 7-5-4-3-2 offsuit, 7462 is a royal flush.
/// Higher is better; equal values tie.
public struct HandRank: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UInt16

    @inlinable public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static func < (lhs: HandRank, rhs: HandRank) -> Bool { lhs.rawValue < rhs.rawValue }

    static let categoryUpperBounds: [UInt16] = {
        var bounds: [UInt16] = []
        var total = 0
        for n in HandCategory.classCounts { total += n; bounds.append(UInt16(total)) }
        return bounds
    }()

    public var category: HandCategory {
        let bounds = HandRank.categoryUpperBounds
        var i = 0
        while rawValue > bounds[i] { i += 1 }
        return HandCategory(rawValue: i)!
    }

    public var description: String { "\(category.name) (#\(rawValue))" }
}

/// A comparable 32-bit encoding of a 5-card hand: category in bits 20..23,
/// then up to five rank "kickers" in significance order, 4 bits each.
/// Both evaluators produce these; the table builder maps them to `HandRank` ordinals.
public enum StrengthCode {
    @inlinable public static func make(_ category: HandCategory, _ kickers: [Int]) -> UInt32 {
        var code = UInt32(category.rawValue) << 20
        for (i, k) in kickers.prefix(5).enumerated() {
            code |= UInt32(k) << UInt32(16 - 4 * i)
        }
        return code
    }

    @inlinable public static func category(_ code: UInt32) -> HandCategory {
        HandCategory(rawValue: Int(code >> 20))!
    }

    /// Top card of the best straight in a 13-bit rank mask, or nil. Wheel returns 3 (the five).
    public static func straightTop(_ mask: Int) -> Int? {
        for top in stride(from: 12, through: 4, by: -1) where (mask >> (top - 4)) & 0x1F == 0x1F {
            return top
        }
        return mask & 0x100F == 0x100F ? 3 : nil
    }

    /// Best hand made only from a suit's 13-bit lane (needs at least 5 bits set).
    public static func flushLane(_ lane: Int) -> UInt32 {
        if let top = straightTop(lane) { return make(.straightFlush, [top]) }
        var kickers: [Int] = []
        var r = 12
        while kickers.count < 5 { if lane & (1 << r) != 0 { kickers.append(r) }; r -= 1 }
        return make(.flush, kickers)
    }

    /// Best non-flush hand from rank counts (5 to 7 cards). Written directly from the
    /// rules rather than by subset enumeration, so it is independent of `ReferenceEvaluator`.
    /// Allocation-light because the table builder calls it ~76,000 times.
    public static func fromRankCounts(_ counts: [Int]) -> UInt32 {
        var present = 0
        var quad = -1, trip1 = -1, trip2 = -1, pair1 = -1, pair2 = -1
        var r = 12
        while r >= 0 {
            let c = counts[r]
            if c > 0 { present |= 1 << r }
            if c >= 4 { if quad < 0 { quad = r } }
            else if c == 3 { if trip1 < 0 { trip1 = r } else if trip2 < 0 { trip2 = r } }
            else if c == 2 { if pair1 < 0 { pair1 = r } else if pair2 < 0 { pair2 = r } }
            r -= 1
        }
        /// Highest `n` present ranks other than `a` and `b`.
        func kickers(_ n: Int, excluding a: Int = -1, _ b: Int = -1) -> [Int] {
            var out: [Int] = []
            var k = 12
            while k >= 0 && out.count < n {
                if present & (1 << k) != 0 && k != a && k != b { out.append(k) }
                k -= 1
            }
            return out
        }
        if quad >= 0 { return make(.quads, [quad] + kickers(1, excluding: quad)) }
        if trip1 >= 0 {
            let pair = max(trip2, pair1)
            if pair >= 0 { return make(.fullHouse, [trip1, pair]) }
        }
        if let top = straightTop(present) { return make(.straight, [top]) }
        if trip1 >= 0 { return make(.trips, [trip1] + kickers(2, excluding: trip1)) }
        if pair2 >= 0 { return make(.twoPair, [pair1, pair2] + kickers(1, excluding: pair1, pair2)) }
        if pair1 >= 0 { return make(.pair, [pair1] + kickers(3, excluding: pair1)) }
        return make(.highCard, kickers(5))
    }
}
