import Testing
@testable import PokerSolver

@Suite("Discounted CFR push/fold")
struct DCFRPushFoldTests {
    let solver = CFRPlusSolver()

    @Test("DCFR converges", arguments: [2.0, 5.0, 10.0, 15.0, 20.0])
    func converges(_ stack: Double) {
        let sol = solver.solve(stack: stack, iterations: 2000, checkpointEvery: 100, algorithm: .dcfr)
        #expect(sol.exploitability < 0.5, "stack \(stack): \(sol.exploitability) mbb/hand")
    }

    @Test func scalarAndSIMDAgree() {
        let a = solver.solve(stack: 10, iterations: 300, checkpointEvery: 300, backend: .scalar, algorithm: .dcfr)
        let b = solver.solve(stack: 10, iterations: 300, checkpointEvery: 300, backend: .simd, algorithm: .dcfr)
        for i in 0..<169 {
            #expect(abs(a.push[i] - b.push[i]) < 1e-3)
            #expect(abs(a.call[i] - b.call[i]) < 1e-3)
        }
    }

    /// Both algorithms find the same equilibrium: same range sizes and game value.
    @Test func agreesWithCFRPlus() {
        let plus = solver.solve(stack: 10, iterations: 3000, checkpointEvery: 3000)
        let dcfr = solver.solve(stack: 10, iterations: 3000, checkpointEvery: 3000, algorithm: .dcfr)
        #expect(abs(plus.pushFraction - dcfr.pushFraction) < 0.005)
        #expect(abs(plus.callFraction - dcfr.callFraction) < 0.005)
        let m = PushFoldMatrices.shared
        #expect(abs(m.gameValue(push: plus.push, call: plus.call, stack: 10) - m.gameValue(push: dcfr.push, call: dcfr.call, stack: 10)) < 1e-4)
    }

    @Test func discountSchedule() {
        let d = CFRPlusSolver.Algorithm.dcfr.discounts(1)!
        #expect(abs(d.pos - 0.5) < 1e-6)                         // 1^1.5 / (1^1.5 + 1)
        #expect(abs(d.neg - 0.5) < 1e-6)                         // beta = 0 halves negative regrets
        #expect(abs(d.sum - 0.25) < 1e-12)                       // (1/2)^2
        #expect(CFRPlusSolver.Algorithm.cfrPlus.discounts(5) == nil)
    }
}
