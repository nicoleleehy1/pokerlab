import PokerCore

/// CFR+ for heads-up push/fold (Tammelin 2014): regret-matching+ (regrets floored at zero),
/// alternating updates, and linearly weighted strategy averaging. Two CPU backends share the
/// same math: a plain scalar loop and a SIMD16 version that vectorises both the
/// counterfactual-value matrix products and the regret updates.
public struct CFRPlusSolver: Sendable {
    public enum Backend: String, Sendable, CaseIterable { case scalar, simd }

    public let matrices: PushFoldMatrices
    public init(matrices: PushFoldMatrices = .shared) { self.matrices = matrices }

    /// Solves one stack depth. Exploitability of the average strategy is recorded every
    /// `checkpointEvery` iterations (it is not counted in the solve timing below it).
    public func solve(stack: Double, iterations: Int, checkpointEvery: Int = 50,
                      backend: Backend = .simd) -> PushFoldSolution {
        var state = State()
        var curve: [PushFoldSolution.Checkpoint] = []
        let clock = ContinuousClock()
        var solveTime = Duration.zero
        var done = 0
        while done < iterations {
            let chunk = min(checkpointEvery, iterations - done)
            let t0 = clock.now
            switch backend {
            case .scalar: runScalar(&state, stack: Float(stack), from: done, count: chunk)
            case .simd: runSIMD(&state, stack: Float(stack), from: done, count: chunk)
            }
            solveTime += clock.now - t0
            done += chunk
            let (p, c) = state.averages()
            curve.append(.init(iteration: done, exploitability: matrices.exploitability(push: p, call: c, stack: stack)))
        }
        let (p, c) = state.averages()
        return PushFoldSolution(stack: stack, push: p, call: c, iterations: iterations, curve: curve,
                                elapsedSeconds: seconds(solveTime))
    }

    /// Solves many stack depths in parallel, one child task per depth.
    public func solve(stacks: [Double], iterations: Int, checkpointEvery: Int = 50,
                      backend: Backend = .simd) async -> [PushFoldSolution] {
        await withTaskGroup(of: (Int, PushFoldSolution).self) { group in
            for (i, s) in stacks.enumerated() {
                group.addTask { (i, self.solve(stack: s, iterations: iterations, checkpointEvery: checkpointEvery, backend: backend)) }
            }
            var out = [PushFoldSolution?](repeating: nil, count: stacks.count)
            for await (i, sol) in group { out[i] = sol }
            return out.map { $0! }
        }
    }

    /// Mutable solver state, padded to the SIMD stride.
    struct State {
        static let s = PushFoldMatrices.stride
        var regretPush = [Float](repeating: 0, count: s)
        var regretFold = [Float](repeating: 0, count: s)
        var regretCall = [Float](repeating: 0, count: s)
        var regretPass = [Float](repeating: 0, count: s)   // BB fold
        var p = [Float](repeating: 0.5, count: s)
        var c = [Float](repeating: 0.5, count: s)
        var sumP = [Double](repeating: 0, count: s)
        var sumC = [Double](repeating: 0, count: s)
        var weight = 0.0

        init() {
            for i in PushFoldMatrices.n..<Self.s { p[i] = 0; c[i] = 0 }
        }

        func averages() -> ([Double], [Double]) {
            let n = PushFoldMatrices.n
            guard weight > 0 else { return (Array(repeating: 0.5, count: n), Array(repeating: 0.5, count: n)) }
            return ((0..<n).map { sumP[$0] / weight }, (0..<n).map { sumC[$0] / weight })
        }
    }

    // MARK: Scalar backend

    func runScalar(_ st: inout State, stack: Float, from start: Int, count: Int) {
        let n = PushFoldMatrices.n, s = PushFoldMatrices.stride
        let a = matrices.a, w = matrices.w, rowSum = matrices.rowSum
        var newP = [Float](repeating: 0, count: s), newC = [Float](repeating: 0, count: s)
        for k in 0..<count {
            let t = Double(start + k + 1)
            // Small blind update against the current calling strategy.
            for i in 0..<n {
                var ac: Float = 0, wc: Float = 0
                for j in 0..<n { ac += a[i * s + j] * st.c[j]; wc += w[i * s + j] * st.c[j] }
                let vPush = stack * ac + rowSum[i] - wc
                let vFold = -0.5 * rowSum[i]
                let pi = st.p[i]
                let v = pi * vPush + (1 - pi) * vFold
                st.sumP[i] += t * Double(pi)
                st.regretPush[i] = max(st.regretPush[i] + vPush - v, 0)
                st.regretFold[i] = max(st.regretFold[i] + vFold - v, 0)
                let sum = st.regretPush[i] + st.regretFold[i]
                newP[i] = sum > 0 ? st.regretPush[i] / sum : 0.5
            }
            st.p = newP
            // Big blind update against the new pushing strategy (alternating updates).
            for j in 0..<n {
                var ap: Float = 0, wp: Float = 0
                for i in 0..<n { ap += a[j * s + i] * st.p[i]; wp += w[j * s + i] * st.p[i] }
                let vCall = stack * ap
                let vFold = -wp
                let cj = st.c[j]
                let v = cj * vCall + (1 - cj) * vFold
                st.sumC[j] += t * Double(cj)
                st.regretCall[j] = max(st.regretCall[j] + vCall - v, 0)
                st.regretPass[j] = max(st.regretPass[j] + vFold - v, 0)
                let sum = st.regretCall[j] + st.regretPass[j]
                newC[j] = sum > 0 ? st.regretCall[j] / sum : 0.5
            }
            st.c = newC
            st.weight += t
        }
    }

    // MARK: SIMD backend

    typealias V = SIMD16<Float>

    func runSIMD(_ st: inout State, stack: Float, from start: Int, count: Int) {
        let n = PushFoldMatrices.n, s = PushFoldMatrices.stride, lanes = s / 16
        let matrices = self.matrices
        matrices.a.withUnsafeBufferPointer { aBuf in
        matrices.w.withUnsafeBufferPointer { wBuf in
        matrices.rowSum.withUnsafeBufferPointer { rBuf in
            let aRaw = UnsafeRawPointer(aBuf.baseAddress!), wRaw = UnsafeRawPointer(wBuf.baseAddress!)
            // Fused (A x, W x) for all rows; x is a padded strategy vector.
            func products(_ x: UnsafeRawPointer, _ outA: UnsafeMutablePointer<Float>, _ outW: UnsafeMutablePointer<Float>) {
                for i in 0..<n {
                    var accA = V(), accW = V()
                    let rowOffset = i * s * 4
                    for l in 0..<lanes {
                        let xv = x.loadUnaligned(fromByteOffset: l * 64, as: V.self)
                        accA.addProduct(aRaw.loadUnaligned(fromByteOffset: rowOffset + l * 64, as: V.self), xv)
                        accW.addProduct(wRaw.loadUnaligned(fromByteOffset: rowOffset + l * 64, as: V.self), xv)
                    }
                    outA[i] = accA.sum(); outW[i] = accW.sum()
                }
            }
            withUnsafeTemporaryAllocation(of: Float.self, capacity: 2 * s) { tmp in
                tmp.initialize(repeating: 0)
                let ax = tmp.baseAddress!, wx = tmp.baseAddress! + s
                let axRaw = UnsafeRawPointer(ax), wxRaw = UnsafeRawPointer(wx)
                let rRaw = UnsafeRawPointer(rBuf.baseAddress!)
                st.regretPush.withUnsafeMutableBytes { rpB in
                st.regretFold.withUnsafeMutableBytes { rfB in
                st.regretCall.withUnsafeMutableBytes { rcB in
                st.regretPass.withUnsafeMutableBytes { rxB in
                st.p.withUnsafeMutableBytes { pB in
                st.c.withUnsafeMutableBytes { cB in
                    let half = V(repeating: 0.5), zero = V(), one = V(repeating: 1), stackV = V(repeating: stack)
                    for k in 0..<count {
                        let t = Double(start + k + 1)
                        for i in 0..<n { st.sumP[i] += t * Double(pB.load(fromByteOffset: i * 4, as: Float.self)) }
                        // Small blind: values, regret-matching+ update, new strategy, 16 classes at a time.
                        products(UnsafeRawPointer(cB.baseAddress!), ax, wx)
                        for l in 0..<lanes {
                            let o = l * 64
                            let r = rRaw.loadUnaligned(fromByteOffset: o, as: V.self)
                            let vPush = stackV * axRaw.loadUnaligned(fromByteOffset: o, as: V.self) + r - wxRaw.loadUnaligned(fromByteOffset: o, as: V.self)
                            let vFold = -half * r
                            let pv = pB.loadUnaligned(fromByteOffset: o, as: V.self)
                            let v = pv * vPush + (one - pv) * vFold
                            let rp = pointwiseMax(rpB.loadUnaligned(fromByteOffset: o, as: V.self) + vPush - v, zero)
                            let rf = pointwiseMax(rfB.loadUnaligned(fromByteOffset: o, as: V.self) + vFold - v, zero)
                            rpB.storeBytes(of: rp, toByteOffset: o, as: V.self)
                            rfB.storeBytes(of: rf, toByteOffset: o, as: V.self)
                            let sum = rp + rf
                            let next = (rp / sum).replacing(with: half, where: sum .<= zero)
                            pB.storeBytes(of: next, toByteOffset: o, as: V.self)
                        }
                        for i in n..<s { pB.storeBytes(of: 0, toByteOffset: i * 4, as: Float.self) }
                        // Big blind, against the updated pushing strategy.
                        for j in 0..<n { st.sumC[j] += t * Double(cB.load(fromByteOffset: j * 4, as: Float.self)) }
                        products(UnsafeRawPointer(pB.baseAddress!), ax, wx)
                        for l in 0..<lanes {
                            let o = l * 64
                            let vCall = stackV * axRaw.loadUnaligned(fromByteOffset: o, as: V.self)
                            let vFold = -wxRaw.loadUnaligned(fromByteOffset: o, as: V.self)
                            let cv = cB.loadUnaligned(fromByteOffset: o, as: V.self)
                            let v = cv * vCall + (one - cv) * vFold
                            let rc = pointwiseMax(rcB.loadUnaligned(fromByteOffset: o, as: V.self) + vCall - v, zero)
                            let rx = pointwiseMax(rxB.loadUnaligned(fromByteOffset: o, as: V.self) + vFold - v, zero)
                            rcB.storeBytes(of: rc, toByteOffset: o, as: V.self)
                            rxB.storeBytes(of: rx, toByteOffset: o, as: V.self)
                            let sum = rc + rx
                            let next = (rc / sum).replacing(with: half, where: sum .<= zero)
                            cB.storeBytes(of: next, toByteOffset: o, as: V.self)
                        }
                        for i in n..<s { cB.storeBytes(of: 0, toByteOffset: i * 4, as: Float.self) }
                        st.weight += t
                    }
                } } } } } }
            }
        } } }
    }
}

func seconds(_ d: Duration) -> Double {
    Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18
}
