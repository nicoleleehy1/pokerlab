import PokerCore

/// Heads-up push/fold with blinds 0.5/1 bb and no ante: the small blind (button) shoves all-in
/// for `stack` bb or folds; the big blind calls or folds. Payoffs are in big blinds, from the
/// small blind's point of view:
///   SB folds            -0.5
///   SB shoves, BB folds +1
///   SB shoves, BB calls  stack * (2 * equity - 1)
///
/// With W[i][j] the probability of dealing SB class i and BB class j (combo pairs with card
/// removal / 1326 / 1225) and A[i][j] = W[i][j] * (2 E[i][j] - 1), every counterfactual value
/// is a matrix-vector product. A is antisymmetric (E[j][i] = 1 - E[i][j]) and W symmetric, so
/// both players' values come from the same two matrices:
///   SB push value  = stack * (A c)_i + rowSum_i - (W c)_i,   SB fold value = -0.5 rowSum_i
///   BB call value  = stack * (A p)_j,                         BB fold value = -(W p)_j
public struct PushFoldMatrices: @unchecked Sendable {
    public static let n = 169
    /// Row stride padded to a multiple of 16 for SIMD16 loads.
    public static let stride = 176
    /// Row-major, n x stride, zero padded.
    public let w: [Float]
    public let a: [Float]
    /// Probability of each SB class (padded to `stride`).
    public let rowSum: [Float]

    public init(table: PreflopEquityTable = .shared) {
        let n = Self.n, s = Self.stride
        let total = 1326.0 * 1225.0
        var w = [Float](repeating: 0, count: n * s)
        var a = [Float](repeating: 0, count: n * s)
        var rowSum = [Float](repeating: 0, count: s) // padded with zeros
        for i in 0..<n {
            var r = 0.0
            for j in 0..<n {
                let wij = Double(table.pairCount[i * n + j]) / total
                let eij = Double(table.equity[i * n + j])
                w[i * s + j] = Float(wij)
                a[i * s + j] = Float(wij * (2 * eij - 1))
                r += wij
            }
            rowSum[i] = Float(r)
        }
        self.w = w; self.a = a; self.rowSum = rowSum
    }

    public static let shared = PushFoldMatrices()

    /// Exploitability of a strategy pair in milli-big-blinds per hand: the average of what each
    /// player's best response gains against the other's strategy. Zero exactly at a Nash equilibrium.
    public func exploitability(push p: [Double], call c: [Double], stack: Double) -> Double {
        let n = Self.n, s = Self.stride
        var ac = [Double](repeating: 0, count: n), wc = ac, ap = ac, wp = ac
        for i in 0..<n {
            var x = 0.0, y = 0.0, u = 0.0, v = 0.0
            for j in 0..<n {
                let aij = Double(a[i * s + j]), wij = Double(w[i * s + j])
                x += aij * c[j]; y += wij * c[j]; u += aij * p[j]; v += wij * p[j]
            }
            ac[i] = x; wc[i] = y; ap[i] = u; wp[i] = v
        }
        // SB best response against BB's calling strategy.
        var sbBest = 0.0
        for i in 0..<n {
            let r = Double(rowSum[i])
            sbBest += max(stack * ac[i] + r - wc[i], -0.5 * r)
        }
        // BB best response against SB's pushing strategy, as SB's resulting value.
        var sbWorst = 0.0
        for i in 0..<n { sbWorst += (1 - p[i]) * -0.5 * Double(rowSum[i]) }
        for j in 0..<n { sbWorst += min(-stack * ap[j], wp[j]) }
        return max(0, (sbBest - sbWorst) / 2) * 1000
    }

    /// Small blind's expected value (bb per hand) when both players follow the given strategies.
    public func gameValue(push p: [Double], call c: [Double], stack: Double) -> Double {
        let n = Self.n, s = Self.stride
        var value = 0.0
        for i in 0..<n {
            var ac = 0.0, wc = 0.0
            for j in 0..<n { ac += Double(a[i * s + j]) * c[j]; wc += Double(w[i * s + j]) * c[j] }
            let r = Double(rowSum[i])
            value += p[i] * (stack * ac + r - wc) + (1 - p[i]) * (-0.5 * r)
        }
        return value
    }
}

/// A solved push/fold spot.
public struct PushFoldSolution: Sendable, Hashable, Codable {
    public struct Checkpoint: Sendable, Hashable, Codable {
        public let iteration: Int
        public let exploitability: Double  // mbb/hand
    }
    public let stack: Double
    /// Average-strategy shove frequency per class (index = HandClass.index).
    public let push: [Double]
    /// Average-strategy call frequency per class.
    public let call: [Double]
    public let iterations: Int
    public let curve: [Checkpoint]
    public let elapsedSeconds: Double

    public var exploitability: Double { curve.last?.exploitability ?? .infinity }

    /// Fraction of all 1,326 combos shoved (weighted by frequency).
    public var pushFraction: Double { Self.comboFraction(push) }
    public var callFraction: Double { Self.comboFraction(call) }

    public func pushes(_ hc: HandClass) -> Double { push[hc.index] }
    public func calls(_ hc: HandClass) -> Double { call[hc.index] }

    /// Classes played at least `threshold` of the time.
    public func pushRange(threshold: Double = 0.5) -> HandRange {
        HandRange(classes: HandClass.all.filter { push[$0.index] >= threshold })
    }
    public func callRange(threshold: Double = 0.5) -> HandRange {
        HandRange(classes: HandClass.all.filter { call[$0.index] >= threshold })
    }

    static func comboFraction(_ s: [Double]) -> Double {
        HandClass.all.reduce(0) { $0 + s[$1.index] * Double($1.comboCount) } / 1326
    }
}
