import Testing
@testable import PokerCore

@Suite("Cards, hand classes and ranges")
struct CardAndRangeTests {
    @Test func cardParsingAndNames() {
        #expect(Card("As") == Card(.ace, .spades))
        #expect(Card("10h") == Card(.ten, .hearts))
        #expect(Card("Xx") == nil)
        #expect(Card(.ace, .spades).spokenName == "Ace of spades")
        #expect(CardSet(parsing: "AsAs") == nil) // duplicate
        #expect(CardSet(parsing: "As Kd, Qh")?.count == 3)
        #expect(CardSet.fullDeck.count == 52)
        #expect(Set(Card.all.map(\.bitIndex)).count == 52)
    }

    @Test func handClassGrid() {
        #expect(Set(HandClass.all).count == 169)
        #expect(HandClass.all.reduce(0) { $0 + $1.combos.count } == 1326)
        #expect(HandClass("AA")!.row == 0 && HandClass("AA")!.column == 0)
        #expect(HandClass("AKs")!.row == 0 && HandClass("AKs")!.column == 1)
        #expect(HandClass("AKo")!.row == 1 && HandClass("AKo")!.column == 0)
        #expect(HandClass("22")!.index == 168)
        for hc in HandClass.all { #expect(HandClass(index: hc.index) == hc) }
        #expect(HandClass("T9s")!.spokenName == "Ten nine suited")
        #expect(HandClass("77")!.spokenName == "Pair of sevens")
    }

    @Test("Range notation expands to the right combo counts", arguments: [
        ("AKs", 4), ("AKo", 12), ("AK", 16), ("QQ", 6), ("QQ+", 18), ("22+", 78),
        ("A5s-A2s", 16), ("22-55", 24), ("55-22", 24), ("ATs+", 16), ("KTo+", 36),
        ("AsKd", 1), ("10s10d", 1), ("random", 1326),
        ("AKs, QQ+, A5s-A2s", 38), ("AA AKs", 10), ("AA, AsAh", 6),
    ])
    func rangeCounts(_ text: String, _ expected: Int) throws {
        #expect(try HandRange(text).comboCount == expected)
    }

    @Test("Invalid ranges throw", arguments: ["AKx", "ZZ", "AKs-QJs", "AAs", "AK:2", "A5s-A2o"])
    func invalid(_ text: String) {
        #expect(throws: RangeParseError.self) { try HandRange(text) }
    }

    @Test func weightsAndCardRemoval() throws {
        let r = try HandRange("AKs:0.5, QQ")
        #expect(r.totalWeight == 4 * 0.5 + 6)
        let aces = try HandRange("AA")
        #expect(aces.removing(CardSet(parsing: "As")!).comboCount == 3)
        #expect(aces.removing(CardSet(parsing: "AsAh")!).comboCount == 1)
        // Blockers: holding the A of spades removes 3 of 16 AK combos.
        #expect(try HandRange("AK").removing(CardSet(parsing: "As")!).comboCount == 12)
        let weights = try HandRange("AKs, QQ").classWeights
        #expect(weights[HandClass("AKs")!.index] == 1)
        #expect(weights[HandClass("AKo")!.index] == 0)
    }

    @Test func descriptionRoundTrips() throws {
        let r = try HandRange("QQ+, AKs, A5s-A2s")
        #expect(try HandRange(r.description) == r)
    }

    @Test func rngIsReproducibleAndStreamsDiffer() {
        var a = Xoshiro256(seed: 1), b = Xoshiro256(seed: 1), c = Xoshiro256(seed: 1, stream: 1)
        let xs = (0..<5).map { _ in a.next() }
        #expect(xs == (0..<5).map { _ in b.next() })
        #expect(xs != (0..<5).map { _ in c.next() })
        var r = Xoshiro256(seed: 3)
        var hist = [Int](repeating: 0, count: 52)
        for _ in 0..<520_000 { hist[Int(r.next(below: 52))] += 1 }
        #expect(hist.allSatisfy { abs($0 - 10_000) < 600 })
    }
}
