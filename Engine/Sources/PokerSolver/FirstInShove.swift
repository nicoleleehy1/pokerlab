import Foundation
import PokerCore

/// First-in shove/fold charts for 6-max, solved with Discounted CFR.
///
/// The game: blinds 0.5/1 bb, no ante, everyone has `stack` bb. The action folds to the hero
/// in `seat`, who shoves all-in or folds. Each player behind, in order, then calls or folds.
/// Simplification: once someone calls, the remaining players fold (overcalls are rare at
/// equilibrium and would need multiway equities). Equities are the exact heads-up class
/// equities from `PreflopEquityTable`; card removal is applied between the hero and each
/// caller, and the players behind are treated as independent of each other.
///
/// With the hero in the small blind this is exactly heads-up push/fold, so the solver is
/// validated against `CFRPlusSolver` (58.3% shove / 37.4% call at 10 bb).
public struct FirstInShoveSolver: Sendable {
    public enum Seat: Int, CaseIterable, Sendable, Hashable, Codable {
        case utg, hj, co, btn, sb, bb
        public var name: String { ["UTG", "HJ", "CO", "BTN", "SB", "BB"][rawValue] }
        public var blind: Double { self == .sb ? 0.5 : self == .bb ? 1 : 0 }
    }

    public struct Solution: Sendable {
        public let seat: Seat
        public let stack: Double
        /// Average shove frequency per hand class.
        public let push: [Double]
        /// Average call frequency per class for each player behind, in seat order.
        public let callers: [(seat: Seat, call: [Double])]
        public let iterations: Int
        /// NashConv: total gain available to players who each switch to a best response (bb/hand).
        public let nashConv: Double
        /// Per-hand EVs (bb, relative to the start of the hand) of shoving and folding.
        public let shoveEV: [Double]
        public let foldEV: Double

        public var pushFraction: Double { HandClass.all.reduce(0) { $0 + push[$1.index] * Double($1.comboCount) } / 1326 }
        public func callFraction(_ s: Seat) -> Double {
            guard let c = callers.first(where: { $0.seat == s })?.call else { return 0 }
            return HandClass.all.reduce(0) { $0 + c[$1.index] * Double($1.comboCount) } / 1326
        }
    }

    let n = 169
    let w: [Double]      // w[i*169+j]: probability of dealing (i, j) to two players, with card removal
    let eq: [Double]     // eq[i*169+j]: equity of class i against class j
    let r: [Double]      // probability of each class

    public init(table: PreflopEquityTable = .shared) {
        let total = 1326.0 * 1225.0
        var w = [Double](repeating: 0, count: 169 * 169), eq = w, r = [Double](repeating: 0, count: 169)
        for i in 0..<169 {
            for j in 0..<169 {
                w[i * 169 + j] = Double(table.pairCount[i * 169 + j]) / total
                eq[i * 169 + j] = Double(table.equity[i * 169 + j])
                r[i] += w[i * 169 + j]
            }
        }
        self.w = w; self.eq = eq; self.r = r
    }

    public static let shared = FirstInShoveSolver()

    /// Strategies for one solve, padded per player.
    struct Profile {
        var push: [Double]
        var calls: [[Double]]
    }

    public func solve(seat: Seat, stack S: Double, iterations: Int = 1500,
                      alpha: Double = 1.5, beta: Double = 0, gamma: Double = 2) -> Solution {
        precondition(seat != .bb, "the big blind can't be first in")
        let behind = Seat.allCases.filter { $0.rawValue > seat.rawValue }
        let m = behind.count
        // Regrets and strategy sums: hero (push, fold), then each caller (call, fold).
        var rPush = [Double](repeating: 0, count: n), rFold = rPush
        var rCall = [[Double]](repeating: [Double](repeating: 0, count: n), count: m), rPass = rCall
        var sumPush = [Double](repeating: 0, count: n), sumCall = rCall
        var weight = 0.0
        var cur = Profile(push: [Double](repeating: 0.5, count: n), calls: [[Double]](repeating: [Double](repeating: 0.5, count: n), count: m))

        func matched(_ a: Double, _ b: Double) -> Double {
            let x = max(a, 0), s = x + max(b, 0)
            return s > 0 ? x / s : 0.5
        }

        for t in 1...iterations {
            let tt = Double(t)
            let pos = pow(tt, alpha) / (pow(tt, alpha) + 1), neg = pow(tt, beta) / (pow(tt, beta) + 1)
            let d = pow(tt / (tt + 1), gamma)
            func disc(_ x: Double) -> Double { x * (x > 0 ? pos : neg) }

            // Hero.
            let (shove, fold) = heroValues(seat: seat, behind: behind, stack: S, profile: cur)
            for i in 0..<n {
                let v = cur.push[i] * shove[i] + (1 - cur.push[i]) * fold
                rPush[i] = disc(rPush[i]) + shove[i] - v
                rFold[i] = disc(rFold[i]) + fold - v
                sumPush[i] += cur.push[i]
                cur.push[i] = matched(rPush[i], rFold[i])
            }
            // Callers, in seat order, against the updated strategies.
            for j in 0..<m {
                let (call, pass) = callerValues(j: j, seat: seat, behind: behind, stack: S, profile: cur)
                for c in 0..<n {
                    let v = cur.calls[j][c] * call[c] + (1 - cur.calls[j][c]) * pass[c]
                    rCall[j][c] = disc(rCall[j][c]) + call[c] - v
                    rPass[j][c] = disc(rPass[j][c]) + pass[c] - v
                    sumCall[j][c] += cur.calls[j][c]
                    cur.calls[j][c] = matched(rCall[j][c], rPass[j][c])
                }
            }
            for i in 0..<n { sumPush[i] *= d }
            for j in 0..<m { for c in 0..<n { sumCall[j][c] *= d } }
            weight = (weight + 1) * d
        }
        let avg = Profile(push: sumPush.map { $0 / weight }, calls: sumCall.map { $0.map { $0 / weight } })
        let (shove, fold) = heroValues(seat: seat, behind: behind, stack: S, profile: avg)
        return Solution(seat: seat, stack: S, push: avg.push,
                        callers: behind.enumerated().map { ($0.element, avg.calls[$0.offset]) },
                        iterations: iterations, nashConv: nashConv(seat: seat, behind: behind, stack: S, profile: avg),
                        shoveEV: shove, foldEV: fold)
    }

    /// Probability that caller `j` calls given the hero holds class i (card removal vs the hero only).
    private func callProbability(_ calls: [Double], heroClass i: Int) -> Double {
        var s = 0.0
        for c in 0..<n { s += w[i * n + c] * calls[c] }
        return s / r[i]
    }

    /// Dead money in a showdown between the hero and caller seat `s`.
    private func dead(hero: Seat, caller: Seat) -> Double { 1.5 - hero.blind - caller.blind }

    /// Per-hand EV of shoving (per class) and of folding, relative to the start of the hand.
    func heroValues(seat: Seat, behind: [Seat], stack S: Double, profile: Profile) -> ([Double], Double) {
        let win = 1.5 - seat.blind        // everyone folds: the hero collects the blinds
        var shove = [Double](repeating: 0, count: n)
        for i in 0..<n {
            var reach = 1.0, ev = 0.0
            for (j, caller) in behind.enumerated() {
                let pot = 2 * S + dead(hero: seat, caller: caller)
                var g = 0.0
                for c in 0..<n { g += w[i * n + c] * profile.calls[j][c] * (eq[i * n + c] * pot - S) }
                ev += reach * g / r[i]
                reach *= 1 - callProbability(profile.calls[j], heroClass: i)
            }
            shove[i] = ev + reach * win
        }
        return (shove, -seat.blind)
    }

    /// Per-hand EVs for caller `j` facing the shove, weighted by how often they face it.
    func callerValues(j: Int, seat: Seat, behind: [Seat], stack S: Double, profile: Profile) -> ([Double], [Double]) {
        let caller = behind[j]
        let pot = 2 * S + dead(hero: seat, caller: caller)
        // Probability the action reaches caller j, per hero class.
        var reachByHero = profile.push
        for i in 0..<n { for k in 0..<j { reachByHero[i] *= 1 - callProbability(profile.calls[k], heroClass: i) } }
        var call = [Double](repeating: 0, count: n), pass = call
        for c in 0..<n {
            var a = 0.0, b = 0.0
            for i in 0..<n {
                let x = w[c * n + i] * reachByHero[i]
                a += x * ((1 - eq[i * n + c]) * pot - S)
                b += x
            }
            call[c] = a / r[c]
            pass[c] = -caller.blind * b / r[c]
        }
        return (call, pass)
    }

    /// Sum over players of (best-response value − current value), in bb per hand.
    func nashConv(seat: Seat, behind: [Seat], stack S: Double, profile: Profile) -> Double {
        var total = 0.0
        let (shove, fold) = heroValues(seat: seat, behind: behind, stack: S, profile: profile)
        for i in 0..<n {
            let cur = profile.push[i] * shove[i] + (1 - profile.push[i]) * fold
            total += r[i] * (max(shove[i], fold) - cur)
        }
        for j in 0..<behind.count {
            let (call, pass) = callerValues(j: j, seat: seat, behind: behind, stack: S, profile: profile)
            for c in 0..<n {
                let cur = profile.calls[j][c] * call[c] + (1 - profile.calls[j][c]) * pass[c]
                total += r[c] * (max(call[c], pass[c]) - cur)
            }
        }
        return total
    }
}
