import Testing
@testable import PokerSolver
#if canImport(Metal)
import Metal
#endif

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

#if canImport(Metal)
@Suite("Discounted CFR on Metal")
struct MetalDCFRTests {
    /// Both GPU kernels run DCFR and agree with the CPU DCFR solver.
    @Test("Metal DCFR matches CPU DCFR", arguments: MetalCFRSolver.Kernel.allCases)
    func metalMatchesCPU(_ kernel: MetalCFRSolver.Kernel) throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }   // no GPU here
        let gpu = try MetalCFRSolver()
        let stacks: [Double] = [5, 10, 20]
        let g = try gpu.solve(stacks: stacks, iterations: 600, checkpointEvery: 600, kernel: kernel, algorithm: .dcfr)
        for (i, s) in stacks.enumerated() {
            let c = CFRPlusSolver().solve(stack: s, iterations: 600, checkpointEvery: 600, algorithm: .dcfr)
            var maxDiff = 0.0
            for k in 0..<169 { maxDiff = max(maxDiff, abs(g[i].push[k] - c.push[k]), abs(g[i].call[k] - c.call[k])) }
            #expect(maxDiff < 0.01, "\(kernel) stack \(s): \(maxDiff)")
            #expect(g[i].exploitability < 0.5)
        }
    }

    /// DCFR on the GPU reaches 0.1 mbb/hand in fewer iterations than CFR+ on the GPU.
    @Test func metalDCFRConvergesFaster() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }   // no GPU here
        let gpu = try MetalCFRSolver()
        func iterationsTo(_ target: Double, _ algorithm: CFRPlusSolver.Algorithm) throws -> Int {
            let sol = try gpu.solve(stacks: [10], iterations: 1000, checkpointEvery: 10, algorithm: algorithm)[0]
            return sol.curve.first { $0.exploitability < target }?.iteration ?? .max
        }
        #expect(try iterationsTo(0.1, .dcfr) < iterationsTo(0.1, .cfrPlus))
    }
}
#endif
