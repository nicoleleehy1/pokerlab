import Testing
import PokerCore
@testable import PokerSolver

private func cards(_ s: String) -> [Card] { CardSet(parsing: s)!.sortedForDisplay }
private func range(_ s: String) -> HandRange { try! HandRange(s) }

@Suite("River solver")
struct RiverSolverTests {
    /// Board 2c 5d 8h Jc Ks: AA beats QQ, QQ beats 43 (no straight, no flush).
    static let board = cards("2c5d8hJcKs")

    /// The clairvoyance game as a river: OOP holds the nuts (AA) or air (43o, weighted to the
    /// same combo count), IP holds bluff-catchers (QQ). One bet size, no raises, IP can't bet.
    @Test("Clairvoyance game matches closed form", arguments: [0.5, 1.0, 2.0])
    func clairvoyance(_ s: Double) throws {
        let air = HandRange(combos: range("43o").combos.map { .init($0.cards, weight: 0.5) })   // 12 combos x 0.5
        let oop = HandRange(combos: range("AA").combos + air.combos)
        let config = RiverTreeConfig(betSizes: [s], raiseSizes: [], allowAllIn: false, maxBets: 1, oopCanBet: true, ipCanBet: false)
        let spot = RiverSpot(board: Self.board, pot: 10, stack: 100, oop: oop, ip: range("QQ"), config: config)
        let solver = try RiverSolver(spot: spot)
        let r = solver.solve(targetExploitability: 0.01, maxIterations: 3000)
        #expect(r.exploitability < 0.05, "exploitability \(r.exploitability)% of pot")
        // Closed form (pot 1): bettor's pot share (1 + 2s) / (2 (1 + s)).
        let ev = solver.expectedValues()
        let share = (ev.oop + 5) / 10
        #expect(abs(share - (1 + 2 * s) / (2 * (1 + s))) < 0.002, "pot share \(share)")
        #expect(abs(ev.oop + ev.ip) < 1e-4, "zero-sum")
        let rootFreqAir = solver.frequencies(at: solver.root, hand: HoleCards("4h3d")!)!
        let rootFreqNuts = solver.frequencies(at: solver.root, hand: HoleCards("AhAd")!)!
        #expect(rootFreqNuts[1] > 0.98, "nuts always bet")
        #expect(abs(rootFreqAir[1] - s / (1 + s)) < 0.02, "bluff frequency \(rootFreqAir[1])")
        let facing = solver.node(path: [1])
        let call = solver.frequencies(at: facing, hand: HoleCards("QhQd")!)!
        #expect(abs(call[1] - 1 / (1 + s)) < 0.02, "call frequency \(call[1])")
    }

    /// AKQ-style river: IP holds the nuts or air (AA / 43o), OOP a bluff-catcher (QQ) and may
    /// bet too. OOP's bets can only win against air that folds anyway, so OOP checks; IP then
    /// plays the clairvoyant bettor's strategy.
    @Test func akqRiver() throws {
        let air = HandRange(combos: range("43o").combos.map { .init($0.cards, weight: 0.5) })
        let ip = HandRange(combos: range("AA").combos + air.combos)
        let config = RiverTreeConfig(betSizes: [1], raiseSizes: [], allowAllIn: false, maxBets: 1)
        let solver = try RiverSolver(spot: RiverSpot(board: Self.board, pot: 10, stack: 100, oop: range("QQ"), ip: ip, config: config))
        let r = solver.solve(targetExploitability: 0.01, maxIterations: 3000)
        #expect(r.exploitability < 0.05)
        let afterCheck = solver.node(path: [0])
        #expect(abs(solver.frequencies(at: afterCheck, hand: HoleCards("4h3d")!)![1] - 0.5) < 0.02)   // s/(1+s) at pot size
        let facing = solver.node(path: [0, 1])
        #expect(abs(solver.frequencies(at: facing, hand: HoleCards("QhQd")!)![1] - 0.5) < 0.02)      // 1/(1+s)
        // IP's value: pot share 3/4 of the pot on the check-bet line.
        let ev = solver.expectedValues()
        #expect(abs((ev.ip + 5) / 10 - 0.75) < 0.003)
    }

    /// The sort-and-sweep showdown and the blocker-sum fold values agree with an O(n²) loop.
    @Test func terminalValuesMatchBruteForce() throws {
        let spot = RiverSpot(board: cards("Ah7d7c3s2h"), pot: 20, stack: 50, oop: .all, ip: range("22+, A2s+, K9o+, T8s+"))
        let solver = try RiverSolver(spot: spot, allowIsomorphism: false)
        var rng = Xoshiro256(seed: 9)
        for p in 0..<2 {
            let opp = solver.sides[1 - p], hero = solver.sides[p]
            var reach = [Float](repeating: 0, count: opp.padded)
            for i in 0..<opp.canonCount { reach[i] = Float(rng.nextUnit()) }
            for node in solver.nodes {
                if case .decision = node.kind { continue }
                let fast = solver.terminalValues(node, player: p, oppReach: reach)
                for c in stride(from: 0, to: hero.canonCount, by: 37) {
                    let i = hero.reps[c]
                    var slow = 0.0
                    for j in 0..<opp.count {
                        let (a, b) = hero.cards[i], (x, y) = opp.cards[j]
                        guard a != x && a != y && b != x && b != y else { continue }
                        let r = Double(reach[opp.canon[j]])
                        switch node.kind {
                        case .fold(let folder):
                            let paid = 10 + (folder == 0 ? node.contributions.0 : node.contributions.1)
                            slow += (folder == p ? -paid : paid) * r
                        case .showdown:
                            let stake = 10 + node.contributions.0
                            if hero.strength[i] > opp.strength[j] { slow += stake * r } else if hero.strength[i] < opp.strength[j] { slow -= stake * r }
                        case .decision: break
                        }
                    }
                    #expect(abs(Double(fast[c]) - slow) < 1e-3 * max(1, abs(slow)), "player \(p) hand \(c): \(fast[c]) vs \(slow)")
                }
            }
        }
    }

    /// A board with two absent suits (hearts and spades are interchangeable) halves most of the
    /// hand list, and the reduced solve matches the full one.
    @Test func suitIsomorphismMatchesFullSolve() throws {
        let spot = RiverSpot(board: cards("2c7c9cJdKd"), pot: 10, stack: 40,
                             oop: range("22+, A2s+, KTs+, QTs+, JTs, ATo+, KJo+"), ip: range("33+, A8s+, KQs, AJo+"))
        let iso = try RiverSolver(spot: spot)
        let full = try RiverSolver(spot: spot, allowIsomorphism: false)
        #expect(iso.usesIsomorphism)
        #expect(iso.canonicalHandCounts.oop < iso.handCounts.oop * 3 / 4)
        iso.iterate(200); full.iterate(200)
        #expect(abs(iso.exploitability() - full.exploitability()) < 1e-3)
        #expect(abs(iso.expectedValues().oop - full.expectedValues().oop) < 1e-3)
    }

    @Test func isomorphismOffForAsymmetricRanges() throws {
        let spot = RiverSpot(board: cards("2c7c9cJdKd"), pot: 10, stack: 40, oop: range("AhKh, AsKs, AhQh"), ip: range("QQ"))
        #expect(try !RiverSolver(spot: spot).usesIsomorphism)
    }

    @Test func realisticSpotConverges() throws {
        let spot = RiverSpot(board: cards("Ks9h5c4d2s"), pot: 20, stack: 80,
                             oop: range("22+, A2s+, K2s+, Q8s+, J8s+, T8s+, 97s+, 86s+, 75s+, 64s+, 54s, A7o+, K9o+, QTo+, JTo"),
                             ip: range("22+, A2s+, K9s+, QTs+, JTs, T9s, 98s, ATo+, KJo+"))
        let solver = try RiverSolver(spot: spot)
        let r = solver.solve(targetExploitability: 0.3, maxIterations: 1000)
        #expect(r.exploitability <= 0.3, "\(r.exploitability)% after \(r.iterations)")
        #expect(r.curve.first!.exploitability > r.exploitability)
        let ev = solver.expectedValues()
        #expect(abs(ev.oop + ev.ip) < 1e-3)
        // Strong hands never fold to a bet: 55 (a set) facing IP's bet after a check.
        let facing = solver.node(path: [0, 1])
        let freq = solver.frequencies(at: facing, hand: HoleCards("5h5d")!)!
        #expect(freq[0] < 0.01)
    }

    @Test func actionEVsAreConsistent() throws {
        let spot = RiverSpot(board: Self.board, pot: 10, stack: 30, oop: range("QQ, 99, 76s"), ip: range("AA, KK, 43o, 76o"))
        let solver = try RiverSolver(spot: spot)
        solver.solve(targetExploitability: 0.05, maxIterations: 3000)
        let facing = solver.node(path: [0, 1])
        let evs = solver.actionEVs(at: facing, path: [0, 1], hand: HoleCards("QhQd")!)!
        #expect(evs.count == solver.nodes[facing].actions.count)
        // Folding loses exactly the half pot owned at the start of the river: EV 0 in pot-share terms.
        #expect(abs(evs[0]) < 1e-4)
        // Mixed actions at equilibrium have (nearly) equal EV.
        let f = solver.frequencies(at: facing, hand: HoleCards("QhQd")!)!
        let used = f.indices.filter { f[$0] > 0.1 }
        if used.count > 1 { #expect(abs(evs[used[0]] - evs[used[1]]) < 0.1) }
    }

    @Test func treeShape() throws {
        let spot = RiverSpot(board: Self.board, pot: 10, stack: 30, oop: range("QQ"), ip: range("AA, 43o"),
                             config: RiverTreeConfig(betSizes: [0.5, 1], raiseSizes: [1], allowAllIn: true, maxBets: 2))
        let solver = try RiverSolver(spot: spot)
        #expect(solver.nodes[solver.root].actions.map(\.label) == ["Check", "Bet 50%", "Bet 100%", "All-in"])
        let facing = solver.node(path: [1])   // IP facing a half-pot bet of 5
        #expect(solver.nodes[facing].actions.map(\.kind) == [.fold, .call, .raise, .allIn])
    }
}
