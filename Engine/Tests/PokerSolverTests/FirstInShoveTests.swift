import Testing
import PokerCore
@testable import PokerSolver

@Suite("First-in shove charts (6-max)")
struct FirstInShoveTests {
    let solver = FirstInShoveSolver.shared

    /// Small blind first in is heads-up push/fold: the charts must match CFRPlusSolver.
    @Test func smallBlindMatchesHeadsUpPushFold() {
        let six = solver.solve(seat: .sb, stack: 10, iterations: 1500)
        let hu = CFRPlusSolver().solve(stack: 10, iterations: 2000, checkpointEvery: 2000, algorithm: .dcfr)
        #expect(abs(six.pushFraction - hu.pushFraction) < 0.01, "\(six.pushFraction) vs \(hu.pushFraction)")
        #expect(abs(six.callFraction(.bb) - hu.callFraction) < 0.01)
        var maxDiff = 0.0
        for k in 0..<169 { maxDiff = max(maxDiff, abs(six.push[k] - hu.push[k])) }
        #expect(maxDiff < 0.05, "max push difference \(maxDiff)")
    }

    /// Ranges widen as fewer players are left behind.
    @Test func laterSeatsShoveWider() {
        let widths = [FirstInShoveSolver.Seat.utg, .hj, .co, .btn, .sb].map { solver.solve(seat: $0, stack: 10).pushFraction }
        for k in 1..<widths.count { #expect(widths[k] > widths[k - 1], "\(widths)") }
    }

    @Test("Converges", arguments: [FirstInShoveSolver.Seat.utg, .co, .btn])
    func converges(_ seat: FirstInShoveSolver.Seat) {
        let s = solver.solve(seat: seat, stack: 12, iterations: 1500)
        #expect(s.nashConv < 0.002, "\(seat.name): NashConv \(s.nashConv) bb/hand")
        #expect(s.push[HandClass("AA")!.index] > 0.99)
        #expect(s.push[HandClass("72o")!.index] < 0.01)
    }

    /// Folding first in costs exactly the hero's blind; shoving AA is clearly +EV.
    @Test func evs() {
        let s = solver.solve(seat: .co, stack: 10)
        #expect(s.foldEV == 0)
        #expect(s.shoveEV[HandClass("AA")!.index] > 1)
        #expect(solver.solve(seat: .sb, stack: 10).foldEV == -0.5)
    }
}
