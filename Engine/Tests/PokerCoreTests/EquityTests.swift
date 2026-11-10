import Testing
@testable import PokerCore

private func hand(_ s: String) -> HoleCards { HoleCards(s)! }
private func board(_ s: String) -> CardSet { CardSet(parsing: s)! }

@Suite("Equity")
struct EquityTests {
    /// All-in preflop matchups, exact enumeration of all 1,712,304 boards.
    /// The AA rows were cross-checked by brute force with `ReferenceEvaluator` over every board
    /// (bit-identical results). Values are suit-specific: suit-disjoint AA vs KK is 81.26%;
    /// the commonly quoted ~82% averages over suit combinations.
    @Test("Known preflop matchups", arguments: [
        ("AsAh", "KdKc", 0.812555),  // aces vs kings, no shared suits
        ("AhKh", "QsQd", 0.462145),  // AKs vs QQ: the classic "coin flip", pair slightly ahead
        ("AhKd", "AsQc", 0.740161),  // domination: AK vs AQ offsuit, about 74%
        ("AsAd", "7h2c", 0.874224),  // best vs worst
        ("AsKs", "AhKh", 0.5),       // mirror: always split or flush either side
    ])
    func preflopExact(_ h1: String, _ h2: String, _ expected: Double) async throws {
        let r = try await EquityCalculator.exact(EquityRequest(hands: [hand(h1), hand(h2)]))
        #expect(r.samples == 1_712_304)
        #expect(abs(r.equities[0] - expected) < 1e-6, "got \(r.equities[0])")
        #expect(abs(r.equities[0] + r.equities[1] - 1) < 1e-12)
    }

    @Test func riverIsDeterministic() async throws {
        let b = board("Ks 9d 4c 2h 2s")
        let r = try await EquityCalculator.exact(EquityRequest(hands: [hand("KhQd"), hand("9s9h")], board: b))
        #expect(r.samples == 1)
        #expect(r.equities == [0, 1])
        let split = try await EquityCalculator.exact(EquityRequest(hands: [hand("3c3d"), hand("5c5d")], board: board("AsKsQsJsTs")))
        #expect(split.equities == [0.5, 0.5])
        #expect(split.tieProbabilities == [1, 1])
    }

    @Test func turnSpotByHand() async throws {
        // AhKh on Qh Jh 2c 7s vs a set of deuces, 44 possible rivers. Counted by hand:
        // hero wins with 3h 4h 5h 6h 8h 9h Th (flush; Th is a royal) and Tc Td Ts (Broadway) = 10.
        // 2h gives villain quads and 7h pairs the board for villain's full house; everything else
        // leaves the set ahead.
        let r = try await EquityCalculator.exact(EquityRequest(hands: [hand("AhKh"), hand("2d2s")], board: board("QhJh2c7s")))
        #expect(r.samples == 44)
        #expect(abs(r.equities[0] - 10.0 / 44.0) < 1e-12)
    }

    @Test func monteCarloAgreesWithExactWithinFourStandardErrors() async throws {
        let spots: [EquityRequest] = [
            EquityRequest(hands: [hand("AsAh"), hand("KdKc")]),
            EquityRequest(hands: [hand("8c7c"), hand("AdKs"), hand("QhQs")]),
            EquityRequest(players: [HandRange(hand("AhKh")), try HandRange("QQ+, AKo")], board: board("Qd 7h 2h")),
        ]
        for spot in spots {
            let exact = try await EquityCalculator.exact(spot)
            let mc = try await EquityCalculator.monteCarlo(spot, trials: 400_000, seed: 99)
            for p in spot.players.indices {
                let diff = abs(exact.equities[p] - mc.equities[p])
                #expect(diff < 4 * mc.standardErrors[p] + 1e-9, "player \(p): exact \(exact.equities[p]) mc \(mc.equities[p]) se \(mc.standardErrors[p])")
            }
        }
    }

    @Test func cardRemovalInRanges() async throws {
        // Hero AsAh vs "AA": only AcAd remains, so it is a near-certain split.
        let r = try await EquityCalculator.exact(EquityRequest(players: [HandRange(hand("AsAh")), try HandRange("AA")]))
        #expect(abs(r.equities[0] - 0.5) < 0.03)
        // Range fully blocked by the board and hero -> error, not a hang.
        await #expect(throws: EquityError.self) {
            _ = try await EquityCalculator.monteCarlo(EquityRequest(players: [HandRange(hand("AsAh")), try HandRange("AsAd, AhAc")]), trials: 10)
        }
    }

    @Test func weightedRangesMatchExactEnumeration() async throws {
        let req = EquityRequest(players: [HandRange(hand("JsJh")), try HandRange("AKs:0.25, 99:1, 72o:0.5")], board: board("Ts 8d 3c"))
        let exact = try await EquityCalculator.exact(req)
        let mc = try await EquityCalculator.monteCarlo(req, trials: 300_000, seed: 5)
        #expect(abs(exact.equities[0] - mc.equities[0]) < 4 * mc.standardErrors[0])
    }

    @Test func multiwayEquitiesSumToOne() async throws {
        let req = EquityRequest(hands: [hand("AsKs"), hand("QhQd"), hand("9c8c")], board: board("Js Tc 2d"))
        let r = try await EquityCalculator.exact(req)
        #expect(abs(r.equities.reduce(0, +) - 1) < 1e-12)
    }

    @Test func monteCarloIsDeterministicForASeed() async throws {
        let req = EquityRequest(players: [try HandRange("AKs, QQ+"), try HandRange("random")])
        let a = try await EquityCalculator.monteCarlo(req, trials: 50_000, seed: 42, parallelism: 4)
        let b = try await EquityCalculator.monteCarlo(req, trials: 50_000, seed: 42, parallelism: 4)
        let c = try await EquityCalculator.monteCarlo(req, trials: 50_000, seed: 43, parallelism: 4)
        #expect(a.equities == b.equities)
        #expect(a.equities != c.equities)
    }

    @Test func standardErrorShrinksWithTrials() async throws {
        let req = EquityRequest(hands: [hand("AhKd"), hand("7s7c")])
        let small = try await EquityCalculator.monteCarlo(req, trials: 10_000, seed: 1)
        let large = try await EquityCalculator.monteCarlo(req, trials: 640_000, seed: 1)
        // 64x the trials -> about 1/8 the standard error.
        let ratio = small.standardErrors[0] / large.standardErrors[0]
        #expect(ratio > 7 && ratio < 9)
    }

    @Test func streamConvergesAndFinishes() async throws {
        var options = EquityCalculator.StreamOptions()
        options.exactThreshold = 0
        options.targetStandardError = 0.002
        let stream = try EquityCalculator.equity(EquityRequest(players: [try HandRange("AKs"), try HandRange("random")]), options: options)
        var snapshots: [EquitySnapshot] = []
        for await s in stream { snapshots.append(s) }
        #expect(snapshots.count >= 1)
        #expect(snapshots.last!.isFinal)
        #expect(snapshots.last!.maxStandardError <= 0.002)
        #expect(zip(snapshots, snapshots.dropFirst()).allSatisfy { $0.samples < $1.samples })
    }

    @Test func streamUsesExactForSmallSpots() async throws {
        let stream = try EquityCalculator.equity(EquityRequest(hands: [hand("AhKh"), hand("2d2s")], board: board("QhJh2c7s")))
        var last: EquitySnapshot?
        for await s in stream { last = s }
        #expect(last?.isExact == true)
        #expect(abs(last!.equities[0] - 10.0 / 44.0) < 1e-12)
    }

    @Test func cancellingTheConsumerStopsTheStream() async throws {
        var options = EquityCalculator.StreamOptions()
        options.exactThreshold = 0
        options.maxTrials = .max          // would run forever unless cancelled
        options.targetStandardError = 0
        let stream = try EquityCalculator.equity(EquityRequest(players: [.all, .all, .all]), options: options)
        let consumer = Task {
            var n = 0
            for await _ in stream { n += 1 }
            return n
        }
        // Cancel only after the producer has started yielding.
        try await Task.sleep(for: .milliseconds(300))
        consumer.cancel()
        let clock = ContinuousClock()
        let start = clock.now
        let count = await consumer.value
        // Iteration ends promptly once cancelled (onTermination cancels the producer task).
        #expect(clock.now - start < .seconds(1))
        #expect(count >= 0)
    }

    @Test func breakingOutOfTheStreamEndsIt() async throws {
        var options = EquityCalculator.StreamOptions()
        options.exactThreshold = 0
        options.maxTrials = .max
        options.targetStandardError = 0
        let stream = try EquityCalculator.equity(EquityRequest(players: [.all, .all]), options: options)
        var seen = 0
        for await s in stream {
            seen += 1
            #expect(!s.isFinal)
            if seen == 3 { break }
        }
        #expect(seen == 3)
    }

    @Test func invalidRequestsThrow() throws {
        #expect(throws: EquityError.needAtLeastTwoPlayers) { _ = try EquityCalculator.equity(EquityRequest(hands: [hand("AsAh")])) }
        #expect(throws: EquityError.invalidBoard) {
            _ = try EquityCalculator.equity(EquityRequest(hands: [hand("AsAh"), hand("KsKh")], board: board("2c3c")))
        }
        #expect(throws: EquityError.emptyRange(player: 1)) {
            _ = try EquityCalculator.equity(EquityRequest(hands: [hand("AsAh"), hand("KsKh")], board: board("Ks 2c 3d")))
        }
    }
}
