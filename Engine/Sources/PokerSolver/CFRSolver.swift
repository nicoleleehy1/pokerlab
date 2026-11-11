import Foundation
import PokerCore

/// CFR+ for heads-up push/fold (Tammelin 2014): regret-matching+ (regrets floored at zero),
/// alternating updates, and linearly weighted strategy averaging. Discounted CFR (Brown &
/// Sandholm 2019) is available as an option: positive regrets are scaled by t^α/(t^α+1),
/// negative ones by t^β/(t^β+1), and earlier strategies are down-weighted by (t/(t+1))^γ.
/// Two CPU backends share the same math: a plain scalar loop and a SIMD16 version that
/// vectorises both the counterfactual-value matrix products and the regret updates.
public struct CFRPlusSolver: Sendable {
    public enum Backend: String, Sendable, CaseIterable { case scalar, simd }

    public enum Algorithm: Hashable, Sendable {
        case cfrPlus
        case dcfr(alpha: Double, beta: Double, gamma: Double)
        /// The parameters the DCFR paper recommends.
        public static let dcfr = Algorithm.dcfr(alpha: 1.5, beta: 0, gamma: 2)

        public var name: String {
            switch self {
            case .cfrPlus: "CFR+"
            case .dcfr(let a, let b, let g): "DCFR(\(a), \(b), \(g))"
            }
        }

        /// Regret discounts (positive, negative) and the strategy-sum discount for iteration t.
        func discounts(_ t: Double) -> (pos: Float, neg: Float, sum: Double)? {
            guard case .dcfr(let a, let b, let g) = self else { return nil }
            let ta = Foundation.pow(t, a), tb = Foundation.pow(t, b)
            return (Float(ta / (ta + 1)), Float(tb / (tb + 1)), Foundation.pow(t / (t + 1), g))
        }
    }

    public let matrices: PushFoldMatrices
    public init(matrices: PushFoldMatrices = .shared) { self.matrices = matrices }

    /// Solves one stack depth. Exploitability of the average strategy is recorded every
    /// `checkpointEvery` iterations (it is not counted in the solve timing below it).
    public func solve(stack: Double, iterations: Int, checkpointEvery: Int = 50,
                      backend: Backend = .simd, algorithm: Algorithm = .cfrPlus) -> PushFoldSolution {
        var state = State()
        var curve: [PushFoldSolution.Checkpoint] = []
        let clock = ContinuousClock()
        var solveTime = Duration.zero
        var done = 0
        while done < iterations {
            let chunk = min(checkpointEvery, iterations - done)
            let t0 = clock.now
            switch backend {
            case .scalar: runScalar(&state, stack: Float(stack), from: done, count: chunk, algorithm: algorithm)
            case .simd: runSIMD(&state, stack: Float(stack), from: done, count: chunk, algorithm: algorithm)
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
                      backend: Backend = .simd, algorithm: Algorithm = .cfrPlus) async -> [PushFoldSolution] {
        await withTaskGroup(of: (Int, PushFoldSolution).self) { group in
            for (i, s) in stacks.enumerated() {
                group.addTask { (i, self.solve(stack: s, iterations: iterations, checkpointEvery: checkpointEvery, backend: backend, algorithm: algorithm)) }
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

        /// DCFR: down-weights everything accumulated so far by (t/(t+1))^γ.
        mutating func discountSums(_ d: Double) {
            for i in sumP.indices { sumP[i] *= d; sumC[i] *= d }
            weight *= d
        }

        func averages() -> ([Double], [Double]) {
            let n = PushFoldMatrices.n
            guard weight > 0 else { return (Array(repeating: 0.5, count: n), Array(repeating: 0.5, count: n)) }
            return ((0..<n).map { sumP[$0] / weight }, (0..<n).map { sumC[$0] / weight })
        }
    }

    // MARK: Scalar backend

    func runScalar(_ st: inout State, stack: Float, from start: Int, count: Int, algorithm: Algorithm = .cfrPlus) {
        let n = PushFoldMatrices.n, s = PushFoldMatrices.stride
        let a = matrices.a, w = matrices.w, rowSum = matrices.rowSum
        var newP = [Float](repeating: 0, count: s), newC = [Float](repeating: 0, count: s)
        for k in 0..<count {
            let t = Double(start + k + 1)
            let dc = algorithm.discounts(t)
            // CFR+ weights iteration t by t; DCFR adds with weight 1 and discounts the sums below.
            let sw = dc == nil ? t : 1
            func update(_ r: Float, _ inst: Float) -> Float {
                guard let dc else { return max(r + inst, 0) }
                return r * (r > 0 ? dc.pos : dc.neg) + inst
            }
            func share(_ a: Float, _ b: Float) -> Float {
                let a = max(a, 0), sum = a + max(b, 0)
                return sum > 0 ? a / sum : 0.5
            }
            // Small blind update against the current calling strategy.
            for i in 0..<n {
                var ac: Float = 0, wc: Float = 0
                for j in 0..<n { ac += a[i * s + j] * st.c[j]; wc += w[i * s + j] * st.c[j] }
                let vPush = stack * ac + rowSum[i] - wc
                let vFold = -0.5 * rowSum[i]
                let pi = st.p[i]
                let v = pi * vPush + (1 - pi) * vFold
                st.sumP[i] += sw * Double(pi)
                st.regretPush[i] = update(st.regretPush[i], vPush - v)
                st.regretFold[i] = update(st.regretFold[i], vFold - v)
                newP[i] = share(st.regretPush[i], st.regretFold[i])
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
                st.sumC[j] += sw * Double(cj)
                st.regretCall[j] = update(st.regretCall[j], vCall - v)
                st.regretPass[j] = update(st.regretPass[j], vFold - v)
                newC[j] = share(st.regretCall[j], st.regretPass[j])
            }
            st.c = newC
            st.weight += sw
            if let dc { st.discountSums(dc.sum) }
        }
    }

    // MARK: SIMD backend

    typealias V = SIMD16<Float>

    func runSIMD(_ st: inout State, stack: Float, from start: Int, count: Int, algorithm: Algorithm = .cfrPlus) {
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
                        let dc = algorithm.discounts(t)
                        let sw = dc == nil ? t : 1
                        let posV = V(repeating: dc?.pos ?? 1), negV = V(repeating: dc?.neg ?? 1)
                        // CFR+: floor at zero. DCFR: discount by sign, no floor.
                        func update(_ old: V, _ inst: V) -> V {
                            if dc == nil { return pointwiseMax(old + inst, zero) }
                            return old * negV.replacing(with: posV, where: old .> zero) + inst
                        }
                        func share(_ a: V, _ b: V) -> V {
                            let a = pointwiseMax(a, zero), sum = a + pointwiseMax(b, zero)
                            return (a / sum).replacing(with: half, where: sum .<= zero)
                        }
                        for i in 0..<n { st.sumP[i] += sw * Double(pB.load(fromByteOffset: i * 4, as: Float.self)) }
                        // Small blind: values, regret-matching+ update, new strategy, 16 classes at a time.
                        products(UnsafeRawPointer(cB.baseAddress!), ax, wx)
                        for l in 0..<lanes {
                            let o = l * 64
                            let r = rRaw.loadUnaligned(fromByteOffset: o, as: V.self)
                            let vPush = stackV * axRaw.loadUnaligned(fromByteOffset: o, as: V.self) + r - wxRaw.loadUnaligned(fromByteOffset: o, as: V.self)
                            let vFold = -half * r
                            let pv = pB.loadUnaligned(fromByteOffset: o, as: V.self)
                            let v = pv * vPush + (one - pv) * vFold
                            let rp = update(rpB.loadUnaligned(fromByteOffset: o, as: V.self), vPush - v)
                            let rf = update(rfB.loadUnaligned(fromByteOffset: o, as: V.self), vFold - v)
                            rpB.storeBytes(of: rp, toByteOffset: o, as: V.self)
                            rfB.storeBytes(of: rf, toByteOffset: o, as: V.self)
                            pB.storeBytes(of: share(rp, rf), toByteOffset: o, as: V.self)
                        }
                        for i in n..<s { pB.storeBytes(of: 0, toByteOffset: i * 4, as: Float.self) }
                        // Big blind, against the updated pushing strategy.
                        for j in 0..<n { st.sumC[j] += sw * Double(cB.load(fromByteOffset: j * 4, as: Float.self)) }
                        products(UnsafeRawPointer(pB.baseAddress!), ax, wx)
                        for l in 0..<lanes {
                            let o = l * 64
                            let vCall = stackV * axRaw.loadUnaligned(fromByteOffset: o, as: V.self)
                            let vFold = -wxRaw.loadUnaligned(fromByteOffset: o, as: V.self)
                            let cv = cB.loadUnaligned(fromByteOffset: o, as: V.self)
                            let v = cv * vCall + (one - cv) * vFold
                            let rc = update(rcB.loadUnaligned(fromByteOffset: o, as: V.self), vCall - v)
                            let rx = update(rxB.loadUnaligned(fromByteOffset: o, as: V.self), vFold - v)
                            rcB.storeBytes(of: rc, toByteOffset: o, as: V.self)
                            rxB.storeBytes(of: rx, toByteOffset: o, as: V.self)
                            cB.storeBytes(of: share(rc, rx), toByteOffset: o, as: V.self)
                        }
                        for i in n..<s { cB.storeBytes(of: 0, toByteOffset: i * 4, as: Float.self) }
                        st.weight += sw
                        if let dc {
                            // Inline (not discountSums): the regret buffers are borrowed here.
                            for i in 0..<n { st.sumP[i] *= dc.sum; st.sumC[i] *= dc.sum }
                            st.weight *= dc.sum
                        }
                    }
                } } } } } }
            }
        } } }
    }
}

func seconds(_ d: Duration) -> Double {
    Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18
}
