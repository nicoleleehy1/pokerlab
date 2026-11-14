import Testing
import PokerCore
@testable import PokerSolver

private func cards(_ s: String) -> [Card] { CardSet(parsing: s)!.sortedForDisplay }
private func range(_ s: String) -> HandRange { try! HandRange(s) }

@Suite("Multi-street solver (turn and flop)")
struct StreetSolverTests {
    static let config = RiverTreeConfig(betSizes: [0.66], raiseSizes: [], allowAllIn: false, maxBets: 1)

    /// On a river board the multi-street solver runs the same DCFR as RiverSolver.
    @Test func matchesRiverSolverOnTheRiver() throws {
        let board = cards("Ks9h5c4d2s")
        let oop = range("22+, A2s+, KTs+, QTs+, JTs, ATo+, KJo+"), ip = range("33+, A8s+, KQs, AJo+")
        let cfg = RiverTreeConfig(betSizes: [0.5, 1], raiseSizes: [1], allowAllIn: true, maxBets: 2)
        let street = try StreetSolver(spot: StreetSpot(board: board, pot: 10, stack: 40, oop: oop, ip: ip, config: cfg))
        let river = try RiverSolver(spot: RiverSpot(board: board, pot: 10, stack: 40, oop: oop, ip: ip, config: cfg), allowIsomorphism: false)
        street.iterate(150); river.iterate(150)
        #expect(abs(street.exploitability() - river.exploitability()) < 0.01, "\(street.exploitability()) vs \(river.exploitability())")
        #expect(abs(street.expectedValues().oop - river.expectedValues().oop) < 0.01)
    }

    /// With no betting allowed, the game value is just the turn equity over every river card.
    @Test func checkDownValueEqualsExactEquity() async throws {
        let board = cards("Qh8c7c3d")
        let oop = range("JJ+, AQs+, T9s, 98s, A5s"), ip = range("TT+, AJs+, KQs, 65s")
        let cfg = RiverTreeConfig(betSizes: [1], raiseSizes: [], allowAllIn: false, maxBets: 1, oopCanBet: false, ipCanBet: false)
        let solver = try StreetSolver(spot: StreetSpot(board: board, pot: 10, stack: 40, oop: oop, ip: ip, config: cfg))
        solver.iterate(1)
        let eq = try await EquityCalculator.exact(EquityRequest(players: [oop, ip], board: CardSet(board))).equities[0]
        #expect(abs(solver.expectedValues().oop - (eq - 0.5) * 10) < 0.01, "EV \(solver.expectedValues().oop) vs equity \(eq)")
    }

    @Test func turnConvergesAndIsZeroSum() throws {
        let spot = StreetSpot(board: cards("Ks9h5c4d"), pot: 10, stack: 30,
                              oop: range("22+, A2s+, K9s+, QTs+, JTs, T9s, 98s, A9o+, KTo+"),
                              ip: range("44+, A5s+, KTs+, QJs, JTs, ATo+, KQo"), config: Self.config)
        let solver = try StreetSolver(spot: spot)
        let r = solver.solve(targetExploitability: 0.5, maxIterations: 600, checkEvery: 25)
        #expect(r.exploitability <= 0.5, "\(r.exploitability)% after \(r.iterations)")
        #expect(r.curve.first!.exploitability > 2 * r.exploitability)
        let ev = solver.expectedValues()
        #expect(abs(ev.oop + ev.ip) < 1e-3)
        #expect(solver.chanceNodeCount > 0)
    }

    /// A small flop solve (narrow ranges, one bet size) converges.
    @Test func smallFlopConverges() throws {
        let spot = StreetSpot(board: cards("Kh8d3c"), pot: 10, stack: 20,
                              oop: range("KK, 88, 33, AK, KQs, QJs, JTs"), ip: range("AA, KK, AK, AQs, KQ"), config: Self.config)
        let solver = try StreetSolver(spot: spot)
        let r = solver.solve(targetExploitability: 1.0, maxIterations: 200, checkEvery: 20)
        #expect(r.exploitability <= 1.0, "\(r.exploitability)% after \(r.iterations)")
        let ev = solver.expectedValues()
        #expect(abs(ev.oop + ev.ip) < 1e-3)
        // Root strategies are available per hand and sum to 1.
        let f = try #require(solver.rootFrequencies(hand: HoleCards("8h8c")!))
        #expect(abs(f.reduce(0, +) - 1) < 1e-4)
    }
}
