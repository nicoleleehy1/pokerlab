import Testing
import PokerCore
@testable import PokerSolver

private let solver = CFRPlusSolver()
private func hc(_ s: String) -> HandClass { HandClass(s)! }

@Suite("Preflop equity table")
struct PreflopEquityTableTests {
    let table = PreflopEquityTable.shared

    @Test func pairCountsHandleCardRemoval() {
        #expect(table.pairCount.reduce(0, +) == 1326 * 1225)
        // Each of the 6 AA combos is disjoint from exactly one other AA combo.
        #expect(table.pairCount[hc("AA").index * 169 + hc("AA").index] == 6)
        #expect(table.pairCount[hc("AKs").index * 169 + hc("AKo").index] == 4 * 6)
        #expect(table.pairCount[hc("72o").index * 169 + hc("AKs").index] == 12 * 4)
    }

    @Test func equitiesAreComplementary() {
        for i in 0..<169 { for j in 0..<169 where table.pairCount[i * 169 + j] > 0 {
            #expect(abs(table.equity[i * 169 + j] + table.equity[j * 169 + i] - 1) < 1e-5)
        } }
        #expect(abs(table.equity(hc("AA"), vs: hc("AA")) - 0.5) < 1e-6)
    }

    /// The shipped table was produced by exact enumeration; spot-check a few class matchups
    /// against fresh Monte Carlo runs over the full class ranges (within 4 standard errors).
    @Test("Matches Monte Carlo on class ranges", arguments: [("AA", "KK"), ("AKs", "QQ"), ("72o", "AA"), ("T9s", "AKo"), ("22", "AKo")])
    func matchesMonteCarlo(_ a: String, _ b: String) async throws {
        let req = EquityRequest(players: [HandRange(classes: [hc(a)]), HandRange(classes: [hc(b)])])
        let mc = try await EquityCalculator.monteCarlo(req, trials: 2_000_000, seed: 11)
        let stored = table.equity(hc(a), vs: hc(b))
        #expect(abs(stored - mc.equities[0]) < 4 * mc.standardErrors[0], "table \(stored) mc \(mc.equities[0]) ± \(mc.standardErrors[0])")
    }
}

@Suite("CFR+ push/fold solver")
struct PushFoldSolverTests {
    /// The convergence guarantee: the average strategy's exploitability (measured by exact best
    /// response) goes to zero. Below 0.5 mbb/hand the strategies are Nash to within noise.
    @Test("Converges to an equilibrium", arguments: [2.0, 5.0, 10.0, 15.0, 20.0])
    func converges(_ stack: Double) {
        let sol = solver.solve(stack: stack, iterations: 2000, checkpointEvery: 100)
        #expect(sol.exploitability < 0.5, "stack \(stack): \(sol.exploitability) mbb/hand")
        #expect(sol.curve.first!.exploitability > 20 * sol.exploitability)
    }

    @Test func scalarAndSIMDBackendsAgree() {
        let a = solver.solve(stack: 10, iterations: 300, checkpointEvery: 300, backend: .scalar)
        let b = solver.solve(stack: 10, iterations: 300, checkpointEvery: 300, backend: .simd)
        for i in 0..<169 {
            #expect(abs(a.push[i] - b.push[i]) < 1e-3)
            #expect(abs(a.call[i] - b.call[i]) < 1e-3)
        }
    }

    /// At 1 bb the big blind is already all-in and must call everything, and every hand has at
    /// least 25% equity against a random hand, so shoving always beats losing the 0.5 bb blind.
    @Test func oneBigBlindShovesEverything() {
        let sol = solver.solve(stack: 1, iterations: 1000)
        #expect(sol.pushFraction > 0.99)
        #expect(sol.callFraction > 0.99)
    }

    @Test("Premium hands always shove and call", arguments: [5.0, 10.0, 20.0])
    func premiums(_ stack: Double) {
        let sol = solver.solve(stack: stack, iterations: 2000)
        for h in ["AA", "KK", "QQ", "JJ", "AKs", "AKo", "AQs"] {
            #expect(sol.pushes(hc(h)) > 0.99, "\(h) push at \(stack)")
            #expect(sol.calls(hc(h)) > 0.99, "\(h) call at \(stack)")
        }
    }

    /// Shape checks against published heads-up push/fold Nash charts (no ante, 0.5/1 blinds):
    /// ranges tighten as stacks get deeper, the shover's range is much wider than the caller's,
    /// and the worst offsuit hands fold at 10 bb or more. Bands are deliberately loose; the
    /// exploitability test above is the strict correctness check.
    @Test func chartShape() {
        let stacks: [Double] = [3, 5, 10, 15, 20]
        let sols = stacks.map { solver.solve(stack: $0, iterations: 2000) }
        for (a, b) in zip(sols, sols.dropFirst()) {
            #expect(a.pushFraction > b.pushFraction)
            #expect(a.callFraction > b.callFraction)
        }
        // From 5 bb up the shover is wider than the caller (at 2-3 bb the big blind, getting a
        // great price, calls wider than the small blind shoves).
        for s in sols where s.stack >= 5 { #expect(s.pushFraction > s.callFraction) }
        let ten = sols[2]
        #expect(ten.pushFraction > 0.45 && ten.pushFraction < 0.70, "10bb push \(ten.pushFraction)")
        #expect(ten.callFraction > 0.25 && ten.callFraction < 0.50, "10bb call \(ten.callFraction)")
        for junk in ["72o", "32o", "82o", "62o"] {
            #expect(ten.pushes(hc(junk)) < 0.01, "\(junk) should fold at 10bb")
            #expect(ten.calls(hc(junk)) < 0.01)
        }
        // Any ace and any pocket pair is a shove at 10 bb.
        for h in ["A2o", "A5o", "22", "33", "K9o"] { #expect(ten.pushes(hc(h)) > 0.99, "\(h) push at 10bb") }
    }

    @Test func gameValueBehavesSensibly() {
        // At 1 bb both players are all-in with random hands: the value is zero by symmetry.
        let one = solver.solve(stack: 1, iterations: 1000)
        #expect(abs(PushFoldMatrices.shared.gameValue(push: one.push, call: one.call, stack: 1)) < 1e-3)
        // Restricting the small blind to shove-or-fold costs more as stacks deepen.
        let values = [5.0, 10, 20].map { s in
            let sol = solver.solve(stack: s, iterations: 2000)
            return PushFoldMatrices.shared.gameValue(push: sol.push, call: sol.call, stack: s)
        }
        #expect(values[0] > values[1] && values[1] > values[2])
    }

    /// Published heads-up Nash push/fold charts put the 10 bb ranges near 58% shove / 37% call.
    @Test func tenBigBlindRangeSizesMatchPublishedCharts() {
        let ten = solver.solve(stack: 10, iterations: 2000)
        #expect(abs(ten.pushFraction - 0.58) < 0.02, "push \(ten.pushFraction)")
        #expect(abs(ten.callFraction - 0.37) < 0.02, "call \(ten.callFraction)")
    }

    #if canImport(Metal)
    @Test func metalMatchesCPU() throws {
        guard let gpu = try? MetalCFRSolver() else { return } // no GPU in this environment
        let stacks: [Double] = [5, 10, 20]
        for kernel in MetalCFRSolver.Kernel.allCases {
        let g = try gpu.solve(stacks: stacks, iterations: 1000, checkpointEvery: 250, kernel: kernel)
        for (i, s) in stacks.enumerated() {
            let c = solver.solve(stack: s, iterations: 1000, checkpointEvery: 250)
            #expect(g[i].exploitability < 1.0)
            var maxDiff = 0.0
            for k in 0..<169 { maxDiff = max(maxDiff, abs(g[i].push[k] - c.push[k]), abs(g[i].call[k] - c.call[k])) }
            #expect(maxDiff < 0.01, "\(kernel) stack \(s): max strategy difference \(maxDiff)")
        }
        }
    }
    #endif
}
