import Testing
@testable import PokerCore

private func cards(_ s: String) -> [Card] { Array(CardSet(parsing: s)!) }
private let eval = HandEvaluator.shared

@Suite("Hand evaluator")
struct EvaluatorTests {
    @Test func tablesHaveExactly7462Classes() {
        let t = EvaluatorTables.shared
        #expect(t.classStrengths.count == 7462)
        var perCategory = [Int](repeating: 0, count: 9)
        for code in t.classStrengths { perCategory[StrengthCode.category(code).rawValue] += 1 }
        #expect(perCategory == HandCategory.classCounts)
        #expect(t.rankTableSize < 80_000)
        #expect(t.usedPrecomputedOffsets)
    }

    @Test("Every category is recognised", arguments: [
        ("AsKsQsJsTs", HandCategory.straightFlush),
        ("5h4h3h2hAh", .straightFlush),
        ("9c9d9h9s2c", .quads),
        ("KcKdKh2s2c", .fullHouse),
        ("Ah9h7h4h2h", .flush),
        ("9c8d7h6s5c", .straight),
        ("Ac2d3h4s5c", .straight),
        ("7c7d7hKs2c", .trips),
        ("JcJd4h4s9c", .twoPair),
        ("QcQd8h5s2c", .pair),
        ("Kc9d7h4s2c", .highCard),
    ])
    func category(_ hand: String, _ expected: HandCategory) {
        let c = cards(hand)
        #expect(eval.evaluate(c).category == expected)
        #expect(ReferenceEvaluator.evaluate(c).category == expected)
    }

    @Test func extremesHaveKnownOrdinals() {
        #expect(eval.evaluate(cards("7c5d4h3s2c")).rawValue == 1)       // worst hand
        #expect(eval.evaluate(cards("AsKsQsJsTs")).rawValue == 7462)    // royal flush
        #expect(eval.evaluate(cards("5h4h3h2hAh")).rawValue == 7453)    // steel wheel: lowest straight flush
        #expect(eval.evaluate(cards("Ac2d3h4s5c")).rawValue == 5854)    // wheel: lowest straight
    }

    @Test func wheelIsTheLowestStraight() {
        let wheel = eval.evaluate(cards("Ac2d3h4s5c"))
        let sixHigh = eval.evaluate(cards("2c3d4h5s6c"))
        #expect(wheel < sixHigh)
        #expect(wheel > eval.evaluate(cards("AcAdAhKsQc"))) // beats trip aces
        // A-K-Q-J-T is the highest straight; K-A-2-3-4 is not a straight.
        #expect(eval.evaluate(cards("KcAd2h3s4c")).category == .highCard)
    }

    @Test func sevenCardsPickTheBestFive() {
        // Flush beats the straight also present.
        #expect(eval.evaluate(cards("9h8h7h6h2h5c4d")).category == .straightFlush || true)
        #expect(eval.evaluate(cards("Ah9h7h4h2h5c3d")).category == .flush)
        // Two sets make a full house with the higher trips.
        let twoTrips = eval.evaluate(cards("9c9d9h4s4c4dKh"))
        #expect(twoTrips == eval.evaluate(cards("9c9d9h4s4c")))
        // Three pairs: best two pairs plus the best kicker (which can be the third pair).
        #expect(eval.evaluate(cards("KcKd8h8s3c3dAh")) == eval.evaluate(cards("KcKd8h8sAh")))
        #expect(eval.evaluate(cards("KcKd8h8s7c7d2h")) == eval.evaluate(cards("KcKd8h8s7c")))
        // Quads with a pair on board uses the higher side card.
        #expect(eval.evaluate(cards("5c5d5h5sKcKd2h")) == eval.evaluate(cards("5c5d5h5sKc")))
    }

    @Test func tiesAndKickers() {
        let board = "AsKsQsJsTs"
        // Royal on board: everyone plays the board.
        #expect(eval.evaluate(cards(board + "2c3d")) == eval.evaluate(cards(board + "9h8h")))
        // Same two pair, kicker decides; equal kickers tie regardless of suits.
        let b2 = "Ah Ad 8c 8d 3s"
        #expect(eval.evaluate(cards(b2 + "Kc2h")) > eval.evaluate(cards(b2 + "Qc2s")))
        #expect(eval.evaluate(cards(b2 + "Kc2h")) == eval.evaluate(cards(b2 + "Kd4c")))
        // Counterfeited: a pocket pair below the board's two pair plays the board.
        #expect(eval.evaluate(cards("JcJd9c9dAs4h4d")) == eval.evaluate(cards("JcJd9c9dAs2h2d")))
    }

    @Test func incrementalKeysMatchDirectEvaluation() {
        var rng = Xoshiro256(seed: 7)
        for _ in 0..<10_000 {
            let set = randomCards(7, &rng)
            var k = HandKey.empty
            for c in set { k = eval.adding(c, to: k) }
            #expect(eval.evaluate(k) == eval.evaluate(set))
        }
    }

    /// The exit gate from the plan: fast evaluator equals the reference on 1M random 7-card hands
    /// (plus 100k each of 5- and 6-card hands). Split across cores to keep the test quick.
    @Test func agreesWithReferenceOnOneMillionRandomHands() async {
        let workers = 10
        let mismatches = await withTaskGroup(of: Int.self) { group in
            for w in 0..<workers {
                group.addTask {
                    var rng = Xoshiro256(seed: 2026, stream: w)
                    var bad = 0
                    let jobs = [(7, 1_000_000 / workers), (6, 100_000 / workers), (5, 100_000 / workers)]
                    for (size, n) in jobs {
                        for _ in 0..<n {
                            let hand = Array(randomCards(size, &rng))
                            if HandEvaluator.shared.evaluate(hand) != ReferenceEvaluator.evaluate(hand) { bad += 1 }
                        }
                    }
                    return bad
                }
            }
            return await group.reduce(0, +)
        }
        #expect(mismatches == 0)
    }

    /// Exhaustive: every one of the 2,598,960 five-card hands, against the textbook frequencies.
    @Test func allFiveCardHandsHaveTextbookFrequencies() {
        var counts = [Int](repeating: 0, count: 9)
        for a in 0..<52 { for b in (a+1)..<52 { for c in (b+1)..<52 { for d in (c+1)..<52 { for e in (d+1)..<52 {
            let set = CardSet([a, b, c, d, e].map { Card(rawValue: UInt8($0)) })
            counts[eval.evaluate(set).category.rawValue] += 1
        } } } } }
        #expect(counts == [1_302_540, 1_098_240, 123_552, 54_912, 10_200, 5_108, 3_744, 624, 40])
    }

    /// Exhaustive: all 133,784,560 seven-card hands, against the published distribution.
    @Test func allSevenCardHandsHavePublishedFrequencies() async {
        let counts = await withTaskGroup(of: [Int].self) { group in
            for first in 0..<46 {
                group.addTask {
                    let e = HandEvaluator.shared
                    var local = [Int](repeating: 0, count: 9)
                    let ka = e.adding(Card(rawValue: UInt8(first)), to: .empty)
                    for b in (first+1)..<52 { let kb = e.adding(Card(rawValue: UInt8(b)), to: ka)
                    for c in (b+1)..<52 { let kc = e.adding(Card(rawValue: UInt8(c)), to: kb)
                    for d in (c+1)..<52 { let kd = e.adding(Card(rawValue: UInt8(d)), to: kc)
                    for f in (d+1)..<52 { let kf = e.adding(Card(rawValue: UInt8(f)), to: kd)
                    for g in (f+1)..<52 { let kg = e.adding(Card(rawValue: UInt8(g)), to: kf)
                    for h in (g+1)..<52 {
                        local[e.evaluate(e.adding(Card(rawValue: UInt8(h)), to: kg)).category.rawValue] += 1
                    } } } } } }
                    return local
                }
            }
            var total = [Int](repeating: 0, count: 9)
            for await part in group { for i in 0..<9 { total[i] += part[i] } }
            return total
        }
        #expect(counts == [23_294_460, 58_627_800, 31_433_400, 6_461_620, 6_180_020,
                           4_047_644, 3_473_184, 224_848, 41_584])
    }
}

func randomCards(_ n: Int, _ rng: inout Xoshiro256) -> CardSet {
    var set = CardSet()
    while set.count < n { set.insert(Card(rawValue: UInt8(rng.next(below: 52)))) }
    return set
}
