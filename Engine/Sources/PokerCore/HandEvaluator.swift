/// Lookup tables for the fast evaluator, built once on first use (a few milliseconds).
///
/// Design (after OMPEval by Henri Ylitie): every rank has a 25-bit key chosen so that the sum
/// of keys of any multiset of up to 7 ranks (at most 4 of each) is unique. A hand's key is
/// the plain sum of its cards' keys, so it can be built incrementally (board once, then add
/// each player's hole cards). Sums are sparse (max ~33.5M), so they are compressed with a
/// row-displacement perfect hash into a 73,775-entry `UInt16` table. Suit counts ride in
/// the upper 32 bits of the same key (one nibble per suit, biased by 3) so a flush is
/// detected with one AND; flushes then use an 8,192-entry table indexed by the suit's lane.
public final class EvaluatorTables: @unchecked Sendable {
    // Immutable after init; raw pointers keep the hot loop free of bounds checks and ARC.
    public static let shared = EvaluatorTables()

    public static let rankKeys: [UInt32] = [
        0x2000, 0x8001, 0x11000, 0x3A000, 0x91000, 0x176005, 0x366000,
        0x41A013, 0x47802E, 0x479068, 0x48C0E4, 0x48F211, 0x494493,
    ]
    static let rowShift: UInt32 = 11
    static let columnMask: UInt32 = (1 << 11) - 1
    public static let suitBias: UInt64 = 0x3333 << 32
    public static let flushCheck: UInt64 = 0x8888 << 32

    let rankTable: UnsafeMutablePointer<UInt16>
    let flushTable: UnsafeMutablePointer<UInt16>
    let rowOffsets: UnsafeMutablePointer<UInt32>
    let cardKeys: UnsafeMutablePointer<UInt64>
    let cardMasks: UnsafeMutablePointer<UInt64>
    /// All 7,462 strength codes in ascending order; index + 1 is the `HandRank`.
    public let classStrengths: [UInt32]
    public let rankTableSize: Int
    let entrySums: [UInt32]
    /// True when the shipped RankHashOffsets verified (no 0.5 s recomputation at launch).
    public let usedPrecomputedOffsets: Bool

    init() {
        // 1. Walk every rank multiset of up to 7 cards once (76,155 count vectors), keeping
        //    each one's key sum and best non-flush strength.
        let keys = EvaluatorTables.rankKeys
        var multisetSums: [UInt32] = []
        var multisetCodes: [UInt32] = []
        multisetSums.reserveCapacity(76_155); multisetCodes.reserveCapacity(76_155)
        var counts = [Int](repeating: 0, count: 13)
        var fiveCardCodes: [UInt32] = []
        func walk(_ rank: Int, _ total: Int, _ sum: UInt32) {
            if rank == 13 {
                guard total >= 5 else { return }
                let code = StrengthCode.fromRankCounts(counts)
                multisetSums.append(sum); multisetCodes.append(code)
                if total == 5 { fiveCardCodes.append(code) }
                return
            }
            var c = 0
            while c <= 4 && total + c <= 7 {
                counts[rank] = c
                walk(rank + 1, total + c, sum &+ UInt32(c) &* keys[rank])
                c += 1
            }
            counts[rank] = 0
        }
        walk(0, 0, 0)

        // 2. Every distinct 5-card class, sorted, defines the HandRank ordinals 1...7462.
        var flushCodes = [UInt32](repeating: 0, count: 8192)
        for lane in 0..<8192 where lane.nonzeroBitCount >= 5 { flushCodes[lane] = StrengthCode.flushLane(lane) }
        var classes = fiveCardCodes
        for lane in 0..<8192 where lane.nonzeroBitCount == 5 { classes.append(flushCodes[lane]) }
        classes.sort()
        var unique: [UInt32] = []
        unique.reserveCapacity(7462)
        for c in classes where unique.last != c { unique.append(c) }
        classStrengths = unique
        let strengths = unique
        func ordinal(_ code: UInt32) -> UInt16 {
            var lo = 0, hi = strengths.count - 1
            while lo < hi { let mid = (lo + hi) / 2; if strengths[mid] < code { lo = mid + 1 } else { hi = mid } }
            precondition(strengths[lo] == code)
            return UInt16(lo + 1)
        }
        var entries: [(sum: UInt32, value: UInt16)] = []
        entries.reserveCapacity(multisetSums.count)
        for i in multisetSums.indices { entries.append((multisetSums[i], ordinal(multisetCodes[i]))) }

        // 3. Row-displacement perfect hash: index = rowOffsets[sum >> 11] + (sum & 2047).
        //    The offsets are generated offline (RankHashOffsets.swift, by the PokerTables tool)
        //    because first-fit packing takes ~0.5 s; they are verified here and recomputed
        //    if they ever disagree with the entries.
        let sums = entries.map(\.sum)
        let rowCount = Int(sums.max()! >> EvaluatorTables.rowShift) + 1
        var offsets = RankHashOffsets.table
        var size = EvaluatorTables.tableSize(sums: sums, offsets: offsets)
        usedPrecomputedOffsets = offsets.count == rowCount && size != nil
        if !usedPrecomputedOffsets {
            offsets = EvaluatorTables.computeRowOffsets(sums: sums)
            size = EvaluatorTables.tableSize(sums: sums, offsets: offsets)
        }
        let finalSize = size!
        entrySums = sums
        rankTableSize = finalSize
        rankTable = .allocate(capacity: finalSize)
        rankTable.initialize(repeating: 0, count: finalSize)
        for e in entries {
            let idx = Int(offsets[Int(e.sum >> EvaluatorTables.rowShift)]) + Int(e.sum & EvaluatorTables.columnMask)
            rankTable[idx] = e.value
        }
        rowOffsets = .allocate(capacity: rowCount)
        rowOffsets.initialize(from: offsets, count: rowCount)

        // 4. Flush table indexed by a suit's 13-bit lane.
        flushTable = .allocate(capacity: 8192)
        flushTable.initialize(repeating: 0, count: 8192)
        for lane in 0..<8192 where lane.nonzeroBitCount >= 5 { flushTable[lane] = ordinal(flushCodes[lane]) }

        // 5. Per-card key (rank key + suit nibble) and mask, indexed by Card.rawValue.
        cardKeys = .allocate(capacity: 52)
        cardMasks = .allocate(capacity: 52)
        for card in Card.all {
            cardKeys[Int(card.rawValue)] = UInt64(keys[Int(card.rank.rawValue)])
                | (1 << (32 + 4 * UInt64(card.suit.rawValue)))
            cardMasks[Int(card.rawValue)] = card.mask
        }
    }

    /// Returns the table size if `offsets` place every sum in a distinct slot, else nil.
    static func tableSize(sums: [UInt32], offsets: [UInt32]) -> Int? {
        var seen = Set<Int>()
        var size = 0
        for sum in sums {
            let row = Int(sum >> rowShift)
            guard row < offsets.count else { return nil }
            let idx = Int(offsets[row]) + Int(sum & columnMask)
            guard seen.insert(idx).inserted else { return nil }
            size = max(size, idx + 1)
        }
        return size
    }

    /// First-fit row displacement: rows (sums >> 11) are placed densest first at the lowest
    /// offset where all their columns land on free slots.
    static func computeRowOffsets(sums: [UInt32]) -> [UInt32] {
        let rowCount = Int(sums.max()! >> rowShift) + 1
        var rows = [[Int]](repeating: [], count: rowCount)
        for s in sums { rows[Int(s >> rowShift)].append(Int(s & columnMask)) }
        let order = (0..<rowCount).filter { !rows[$0].isEmpty }.sorted {
            rows[$0].count != rows[$1].count ? rows[$0].count > rows[$1].count : $0 < $1
        }
        let capacity = sums.count * 2 + 4096
        var occupied = [Bool](repeating: false, count: capacity + 1)
        var nextFree = Array(0...capacity) // union-find "next free slot"
        func findFree(_ i: Int) -> Int {
            var root = i
            while nextFree[root] != root { root = nextFree[root] }
            var j = i
            while nextFree[j] != root { let n = nextFree[j]; nextFree[j] = root; j = n }
            return root
        }
        var offsets = [UInt32](repeating: 0, count: rowCount)
        for row in order {
            let cols = rows[row].sorted()
            var slot = findFree(cols[0])
            var off = slot - cols[0]
            while cols.contains(where: { occupied[off + $0] }) {
                slot = findFree(slot + 1)
                off = slot - cols[0]
            }
            for c in cols { occupied[off + c] = true; nextFree[off + c] = off + c + 1 }
            offsets[row] = UInt32(off)
        }
        return offsets
    }

    /// Swift source for RankHashOffsets.swift (used by the PokerTables generator).
    public static func generateRowOffsetsSource() -> String {
        let t = EvaluatorTables.shared
        let offsets = computeRowOffsets(sums: t.entrySums)
        var lines = ["// Generated by `swift run -c release PokerTables offsets`. Do not edit.",
                     "// Row offsets for the evaluator's perfect hash; verified at load time.",
                     "enum RankHashOffsets {",
                     "    static let table: [UInt32] = ["]
        var line = "       "
        for (i, o) in offsets.enumerated() {
            line += " \(o),"
            if i % 12 == 11 { lines.append(line); line = "       " }
        }
        if line.count > 7 { lines.append(line) }
        lines.append("    ]")
        lines.append("}")
        return lines.joined(separator: "\n") + "\n"
    }

    public func handRank(forStrength code: UInt32) -> HandRank {
        var lo = 0, hi = classStrengths.count - 1
        while lo < hi { let mid = (lo + hi) / 2; if classStrengths[mid] < code { lo = mid + 1 } else { hi = mid } }
        precondition(classStrengths[lo] == code, "unknown strength code")
        return HandRank(rawValue: UInt16(lo + 1))
    }
}

/// Incrementally built hand: summed card keys plus the card mask.
public struct HandKey: Hashable, Sendable {
    public var key: UInt64
    public var mask: UInt64

    @inlinable public init(key: UInt64, mask: UInt64) { self.key = key; self.mask = mask }
    public static let empty = HandKey(key: EvaluatorTables.suitBias, mask: 0)

    @inlinable public func adding(_ other: HandKey) -> HandKey {
        // Both carry the suit bias; remove one copy.
        HandKey(key: key &+ other.key &- EvaluatorTables.suitBias, mask: mask | other.mask)
    }
}

/// Fast 5-to-7-card evaluator. A value type holding raw pointers into the shared tables,
/// so each worker can copy it into its hot loop.
public struct HandEvaluator: @unchecked Sendable {
    @usableFromInline let rankTable: UnsafePointer<UInt16>
    @usableFromInline let flushTable: UnsafePointer<UInt16>
    @usableFromInline let rowOffsets: UnsafePointer<UInt32>
    @usableFromInline let cardKeys: UnsafePointer<UInt64>
    @usableFromInline let cardMasks: UnsafePointer<UInt64>

    public init(tables: EvaluatorTables = .shared) {
        rankTable = UnsafePointer(tables.rankTable)
        flushTable = UnsafePointer(tables.flushTable)
        rowOffsets = UnsafePointer(tables.rowOffsets)
        cardKeys = UnsafePointer(tables.cardKeys)
        cardMasks = UnsafePointer(tables.cardMasks)
    }

    public static let shared = HandEvaluator()

    @inlinable public func key(for card: Card) -> HandKey {
        HandKey(key: cardKeys[Int(card.rawValue)] &+ EvaluatorTables.suitBias, mask: cardMasks[Int(card.rawValue)])
    }

    @inlinable public func adding(_ card: Card, to hand: HandKey) -> HandKey {
        HandKey(key: hand.key &+ cardKeys[Int(card.rawValue)], mask: hand.mask | cardMasks[Int(card.rawValue)])
    }

    @inlinable public func key(for cards: CardSet) -> HandKey {
        var k = HandKey.empty
        var m = cards.rawValue
        while m != 0 {
            let bit = m.trailingZeroBitCount
            m &= m &- 1
            // bit = suit * 16 + rank  ->  card raw = rank * 4 + suit
            k.key &+= cardKeys[(bit & 15) &* 4 &+ (bit &>> 4)]
        }
        k.mask = cards.rawValue
        return k
    }

    /// Evaluates a hand of 5...7 cards given its accumulated key.
    @inlinable public func evaluate(_ hand: HandKey) -> HandRank {
        let flush = hand.key & EvaluatorTables.flushCheck
        if flush != 0 {
            let suit = UInt64((flush &>> 32).trailingZeroBitCount &>> 2)
            let lane = Int(truncatingIfNeeded: (hand.mask &>> (suit &* 16)) & 0x1FFF)
            return HandRank(rawValue: flushTable[lane])
        }
        let sum = UInt32(truncatingIfNeeded: hand.key)
        let index = Int(rowOffsets[Int(sum &>> 11)]) &+ Int(sum & 0x7FF)
        return HandRank(rawValue: rankTable[index])
    }

    @inlinable public func evaluate(_ cards: CardSet) -> HandRank { evaluate(key(for: cards)) }

    public func evaluate(_ cards: [Card]) -> HandRank { evaluate(CardSet(cards)) }
}
