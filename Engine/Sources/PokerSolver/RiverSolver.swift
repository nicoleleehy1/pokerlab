import Foundation
import PokerCore

/// Bet-size abstraction for a river subgame.
public struct RiverTreeConfig: Hashable, Sendable {
    /// Bet sizes as fractions of the pot (1-3 sizes).
    public var betSizes: [Double]
    /// Raise sizes as fractions of the pot after calling.
    public var raiseSizes: [Double]
    public var allowAllIn: Bool
    /// Bets plus raises allowed in total (1 = no raises).
    public var maxBets: Int
    public var oopCanBet: Bool
    /// Whether the in-position player may bet after a check.
    public var ipCanBet: Bool

    public init(betSizes: [Double] = [0.33, 0.75], raiseSizes: [Double] = [0.75], allowAllIn: Bool = true,
                maxBets: Int = 3, oopCanBet: Bool = true, ipCanBet: Bool = true) {
        precondition(!betSizes.isEmpty || !oopCanBet && !ipCanBet)
        self.betSizes = betSizes; self.raiseSizes = raiseSizes; self.allowAllIn = allowAllIn
        self.maxBets = maxBets; self.oopCanBet = oopCanBet; self.ipCanBet = ipCanBet
    }
}

/// A river spot: five board cards, both ranges, the pot and the effective stack behind.
/// Player 0 is out of position (acts first), player 1 in position.
public struct RiverSpot: Hashable, Sendable {
    public var board: [Card]
    public var pot: Double
    public var stack: Double
    public var ranges: [HandRange]
    public var config: RiverTreeConfig

    public init(board: [Card], pot: Double, stack: Double, oop: HandRange, ip: HandRange, config: RiverTreeConfig = .init()) {
        precondition(board.count == 5, "a river spot needs five board cards")
        self.board = board; self.pot = pot; self.stack = stack; ranges = [oop, ip]; self.config = config
    }
}

public enum RiverSolverError: Error, Equatable, Sendable { case emptyRange(player: Int), noCompatibleHands }

/// Full-range river solver: Discounted CFR (1.5, 0, 2) over all hands at once, with
/// - suit isomorphism: hands that map onto each other under a suit permutation that fixes the
///   board share one strategy row (when both ranges are symmetric under it);
/// - O(n) terminal evaluation: hands are sorted by strength once (the board is fixed), and
///   showdowns are a two-pointer sweep with per-card blocker sums for card removal;
/// - SIMD8 loops for regret matching, regret updates and value accumulation.
///
/// Payoffs use the pot-share convention: each player owns half the starting pot, so a showdown
/// is worth ±(pot/2 + amount put in) and the game is zero-sum. Add pot/2 for "share of pot".
public final class RiverSolver: @unchecked Sendable {
    public enum ActionKind: Hashable, Sendable { case check, call, fold, bet, raise, allIn }

    public struct Action: Hashable, Sendable {
        public let kind: ActionKind
        /// Total chips the actor has put in on the river after the action.
        public let to: Double
        public let label: String
    }

    public struct Node: Sendable {
        public enum Kind: Hashable, Sendable { case decision(player: Int), fold(folder: Int), showdown }
        public let kind: Kind
        /// River contributions (OOP, IP) on reaching this node.
        public let contributions: (Double, Double)
        public let actions: [Action]
        public let children: [Int]
        let offset: Int     // into regret / strategy-sum storage (decision nodes)
        public var potHere: Double = 0
    }

    /// One player's hands with everything precomputed.
    struct Side {
        var cards: [(UInt8, UInt8)] = []       // full list
        var weight: [Float] = []
        var strength: [UInt16] = []
        var canon: [Int] = []                  // full -> canonical
        var reps: [Int] = []                   // canonical -> representative full index
        var multiplicity: [Float] = []         // orbit size per canonical hand
        var sortedFull: [Int] = []             // full indices by strength ascending
        var sortedReps: [Int] = []             // canonical indices by strength ascending
        var comboIndex = [Int](repeating: -1, count: 52 * 52)
        var count: Int { cards.count }
        var canonCount: Int { reps.count }
        var padded: Int { (canonCount + 7) / 8 * 8 }
    }

    public let spot: RiverSpot
    public private(set) var nodes: [Node] = []
    public let root = 0
    var sides: [Side] = [Side(), Side()]
    var regrets: [Float] = []
    var strategySum: [Float] = []
    public private(set) var iteration = 0
    public private(set) var usesIsomorphism = false
    /// Normaliser: total weight of compatible (OOP, IP) hand pairs.
    let pairMass: Double

    // MARK: Setup

    /// `allowIsomorphism: false` solves every hand separately (for testing the reduction).
    public init(spot: RiverSpot, allowIsomorphism: Bool = true) throws {
        self.spot = spot
        let boardSet = CardSet(spot.board)
        let eval = HandEvaluator.shared
        let boardKey = eval.key(for: boardSet)
        for p in 0..<2 {
            let combos = spot.ranges[p].removing(boardSet).combos
            guard !combos.isEmpty else { throw RiverSolverError.emptyRange(player: p) }
            var s = Side()
            for c in combos {
                let a = c.cards.high.rawValue, b = c.cards.low.rawValue
                s.comboIndex[Int(a) * 52 + Int(b)] = s.cards.count
                s.comboIndex[Int(b) * 52 + Int(a)] = s.cards.count
                s.cards.append((a, b))
                s.weight.append(Float(c.weight))
                let key = eval.adding(c.cards.low, to: eval.adding(c.cards.high, to: boardKey))
                s.strength.append(eval.evaluate(key).rawValue)
            }
            sides[p] = s
        }
        // Suit isomorphism: suit permutations that map the board onto itself.
        let perms = Self.boardPreservingSuitPermutations(spot.board)
        let built = sides
        let symmetric = allowIsomorphism && perms.count > 1 && (0..<2).allSatisfy { p in
            let s = built[p]
            return perms.allSatisfy { perm in
                (0..<s.count).allSatisfy { i in
                    let j = s.comboIndex[Int(Self.map(s.cards[i].0, perm)) * 52 + Int(Self.map(s.cards[i].1, perm))]
                    return j >= 0 && s.weight[j] == s.weight[i]
                }
            }
        }
        usesIsomorphism = symmetric
        for p in 0..<2 {
            var s = sides[p]
            s.canon = Array(repeating: -1, count: s.count)
            for i in 0..<s.count where s.canon[i] < 0 {
                let c = s.reps.count
                s.reps.append(i)
                var orbit: Set<Int> = [i]
                if symmetric {
                    for perm in perms {
                        orbit.insert(s.comboIndex[Int(Self.map(s.cards[i].0, perm)) * 52 + Int(Self.map(s.cards[i].1, perm))])
                    }
                }
                for j in orbit { s.canon[j] = c }
                s.multiplicity.append(Float(orbit.count))
            }
            s.sortedFull = (0..<s.count).sorted { s.strength[$0] < s.strength[$1] }
            s.sortedReps = (0..<s.canonCount).sorted { s.strength[s.reps[$0]] < s.strength[s.reps[$1]] }
            sides[p] = s
        }
        var mass = 0.0
        for i in 0..<sides[0].count {
            let (a, b) = sides[0].cards[i]
            for j in 0..<sides[1].count {
                let (c, d) = sides[1].cards[j]
                if a != c && a != d && b != c && b != d { mass += Double(sides[0].weight[i]) * Double(sides[1].weight[j]) }
            }
        }
        guard mass > 0 else { throw RiverSolverError.noCompatibleHands }
        pairMass = mass
        var storage = 0
        buildTree(&storage)
        regrets = Array(repeating: 0, count: storage)
        strategySum = Array(repeating: 0, count: storage)
    }

    static func map(_ card: UInt8, _ perm: [UInt8]) -> UInt8 { (card & ~3) | perm[Int(card & 3)] }

    static func boardPreservingSuitPermutations(_ board: [Card]) -> [[UInt8]] {
        var out: [[UInt8]] = []
        let boardRaw = Set(board.map(\.rawValue))
        func permute(_ prefix: [UInt8], _ rest: [UInt8]) {
            if rest.isEmpty {
                if Set(boardRaw.map { map($0, prefix) }) == boardRaw { out.append(prefix) }
                return
            }
            for (i, x) in rest.enumerated() { var r = rest; r.remove(at: i); permute(prefix + [x], r) }
        }
        permute([], [0, 1, 2, 3])
        return out
    }

    // MARK: Tree

    private func buildTree(_ storage: inout Int) {
        nodes = []
        _ = build(player: 0, c: (0, 0), bets: 0, afterCheck: false, &storage)
    }

    private func label(_ kind: ActionKind, _ to: Double, pot: Double, facing: Double) -> String {
        func amount(_ x: Double) -> String { x == x.rounded() ? String(Int(x)) : String(format: "%.1f", x) }
        switch kind {
        case .check: return "Check"
        case .call: return "Call"
        case .fold: return "Fold"
        case .allIn: return "All-in"
        case .bet: return "Bet \(Int(((to - facing) / pot * 100).rounded()))%"
        case .raise: return "Raise to \(amount(to))"
        }
    }

    @discardableResult
    private func build(player: Int, c: (Double, Double), bets: Int, afterCheck: Bool, _ storage: inout Int) -> Int {
        let cfg = spot.config, stack = spot.stack
        let mine = player == 0 ? c.0 : c.1, theirs = player == 0 ? c.1 : c.0
        let pot = spot.pot + c.0 + c.1
        var actions: [Action] = []
        if mine == theirs {
            actions.append(Action(kind: .check, to: mine, label: "Check"))
            let canBet = player == 0 ? cfg.oopCanBet : cfg.ipCanBet
            if canBet && mine < stack {
                for s in cfg.betSizes {
                    let to = min(stack, mine + s * pot)
                    let kind: ActionKind = to >= stack ? .allIn : .bet
                    if !actions.contains(where: { abs($0.to - to) < 1e-9 }) { actions.append(Action(kind: kind, to: to, label: label(kind, to, pot: pot, facing: mine))) }
                }
                if cfg.allowAllIn && !actions.contains(where: { $0.kind == .allIn }) { actions.append(Action(kind: .allIn, to: stack, label: "All-in")) }
            }
        } else {
            actions.append(Action(kind: .fold, to: mine, label: "Fold"))
            actions.append(Action(kind: .call, to: theirs, label: "Call"))
            if bets < cfg.maxBets && theirs < stack {
                let potAfterCall = spot.pot + 2 * theirs
                for s in cfg.raiseSizes {
                    let to = min(stack, theirs + s * potAfterCall)
                    let kind: ActionKind = to >= stack ? .allIn : .raise
                    if !actions.contains(where: { $0.kind != .fold && abs($0.to - to) < 1e-9 }) { actions.append(Action(kind: kind, to: to, label: label(kind, to, pot: pot, facing: mine))) }
                }
                if cfg.allowAllIn && !actions.contains(where: { $0.kind == .allIn }) { actions.append(Action(kind: .allIn, to: stack, label: "All-in")) }
            }
        }
        let index = nodes.count
        nodes.append(Node(kind: .decision(player: player), contributions: c, actions: actions, children: [], offset: storage, potHere: pot))
        storage += actions.count * sides[player].padded
        var children: [Int] = []
        for a in actions {
            let nc = player == 0 ? (a.to, c.1) : (c.0, a.to)
            switch a.kind {
            case .fold:
                children.append(leaf(.fold(folder: player), c))
            case .call:
                children.append(leaf(.showdown, nc))
            case .check:
                if player == 0 { children.append(build(player: 1, c: nc, bets: bets, afterCheck: true, &storage)) }
                else { children.append(leaf(.showdown, nc)) }
            case .bet, .raise, .allIn:
                children.append(build(player: 1 - player, c: nc, bets: bets + 1, afterCheck: false, &storage))
            }
        }
        let n = nodes[index]
        nodes[index] = Node(kind: n.kind, contributions: n.contributions, actions: n.actions, children: children, offset: n.offset, potHere: pot)
        return index
    }

    private func leaf(_ kind: Node.Kind, _ c: (Double, Double)) -> Int {
        nodes.append(Node(kind: kind, contributions: c, actions: [], children: [], offset: 0, potHere: spot.pot + c.0 + c.1))
        return nodes.count - 1
    }

    // MARK: Sizes

    public var handCounts: (oop: Int, ip: Int) { (sides[0].count, sides[1].count) }
    public var canonicalHandCounts: (oop: Int, ip: Int) { (sides[0].canonCount, sides[1].canonCount) }
    public var decisionNodeCount: Int { nodes.filter { if case .decision = $0.kind { true } else { false } }.count }
    /// Bytes held by the solver's regret and strategy-sum tables.
    public var storageBytes: Int { (regrets.count + strategySum.count) * MemoryLayout<Float>.stride }

    // MARK: Vectors

    typealias V8 = SIMD8<Float>

    /// Opponent reach in full-index order from canonical reach.
    func expand(_ r: [Float], side p: Int) -> [Float] {
        let s = sides[p]
        var out = [Float](repeating: 0, count: s.count)
        for i in 0..<s.count { out[i] = r[s.canon[i]] }
        return out
    }

    /// Counterfactual values of player p's canonical hands at a terminal, given the
    /// opponent's canonical reach.
    func terminalValues(_ node: Node, player p: Int, oppReach: [Float]) -> [Float] {
        let hero = sides[p], opp = sides[1 - p]
        let full = expand(oppReach, side: 1 - p)
        var out = [Float](repeating: 0, count: hero.padded)
        let half = spot.pot / 2
        switch node.kind {
        case .fold(let folder):
            let paid = Float(half + (folder == 0 ? node.contributions.0 : node.contributions.1))
            let payoff = folder == p ? -paid : paid
            var total: Float = 0
            var perCard = [Float](repeating: 0, count: 52)
            for j in 0..<opp.count {
                let r = full[j]
                total += r; perCard[Int(opp.cards[j].0)] += r; perCard[Int(opp.cards[j].1)] += r
            }
            for c in 0..<hero.canonCount {
                let i = hero.reps[c]
                let (a, b) = hero.cards[i]
                var mass = total - perCard[Int(a)] - perCard[Int(b)]
                let same = opp.comboIndex[Int(a) * 52 + Int(b)]
                if same >= 0 { mass += full[same] }
                out[c] = payoff * mass
            }
        case .showdown:
            let stake = Float(half + node.contributions.0)   // equal contributions at showdown
            var perCard = [Float](repeating: 0, count: 52)
            // Weaker opponent hands: ascending sweep.
            var acc: Float = 0, j = 0
            var win = [Float](repeating: 0, count: hero.canonCount)
            for c in hero.sortedReps {
                let i = hero.reps[c], str = hero.strength[i]
                while j < opp.count, opp.strength[opp.sortedFull[j]] < str {
                    let k = opp.sortedFull[j], r = full[k]
                    acc += r; perCard[Int(opp.cards[k].0)] += r; perCard[Int(opp.cards[k].1)] += r
                    j += 1
                }
                win[c] = acc - perCard[Int(hero.cards[i].0)] - perCard[Int(hero.cards[i].1)]
            }
            // Stronger opponent hands: descending sweep.
            for x in 0..<52 { perCard[x] = 0 }
            acc = 0; j = opp.count - 1
            for c in hero.sortedReps.reversed() {
                let i = hero.reps[c], str = hero.strength[i]
                while j >= 0, opp.strength[opp.sortedFull[j]] > str {
                    let k = opp.sortedFull[j], r = full[k]
                    acc += r; perCard[Int(opp.cards[k].0)] += r; perCard[Int(opp.cards[k].1)] += r
                    j -= 1
                }
                let lose = acc - perCard[Int(hero.cards[i].0)] - perCard[Int(hero.cards[i].1)]
                out[c] = stake * (win[c] - lose)
            }
        case .decision:
            preconditionFailure("not a terminal")
        }
        return out
    }

    /// Regret-matched strategy at a decision node: one row of `padded` per action.
    func currentStrategy(_ node: Node, player p: Int) -> [Float] {
        let n = sides[p].padded, k = node.actions.count
        var out = [Float](repeating: 0, count: n * k)
        regrets.withUnsafeBufferPointer { R in
            out.withUnsafeMutableBufferPointer { S in
                let base = UnsafeRawPointer(R.baseAddress! + node.offset), sOut = UnsafeMutableRawPointer(S.baseAddress!)
                let zero = V8(), uniform = V8(repeating: 1 / Float(k))
                for l in stride(from: 0, to: n, by: 8) {
                    var sum = V8()
                    for a in 0..<k { sum += pointwiseMax(base.loadUnaligned(fromByteOffset: (a * n + l) * 4, as: V8.self), zero) }
                    for a in 0..<k {
                        let r = pointwiseMax(base.loadUnaligned(fromByteOffset: (a * n + l) * 4, as: V8.self), zero)
                        sOut.storeBytes(of: (r / sum).replacing(with: uniform, where: sum .<= zero), toByteOffset: (a * n + l) * 4, as: V8.self)
                    }
                }
            }
        }
        return out
    }

    func averageStrategy(_ node: Node, player p: Int) -> [Float] {
        let n = sides[p].padded, k = node.actions.count
        var out = [Float](repeating: 0, count: n * k)
        for h in 0..<n {
            var sum: Float = 0
            for a in 0..<k { sum += strategySum[node.offset + a * n + h] }
            for a in 0..<k { out[a * n + h] = sum > 0 ? strategySum[node.offset + a * n + h] / sum : 1 / Float(k) }
        }
        return out
    }

    // MARK: DCFR

    static let alpha = 1.5, beta = 0.0, gamma = 2.0

    /// Runs `count` DCFR iterations (alternating updates).
    public func iterate(_ count: Int) {
        for _ in 0..<count {
            iteration += 1
            let t = Double(iteration)
            let ta = pow(t, Self.alpha), tb = pow(t, Self.beta)
            let pos = Float(ta / (ta + 1)), neg = Float(tb / (tb + 1)), d = Float(pow(t / (t + 1), Self.gamma))
            for p in 0..<2 {
                let selfReach = canonicalWeights(p), oppReach = canonicalWeights(1 - p)
                _ = cfr(root, p, selfReach, oppReach, pos, neg, d)
            }
        }
    }

    func canonicalWeights(_ p: Int) -> [Float] {
        let s = sides[p]
        var w = [Float](repeating: 0, count: s.padded)
        for c in 0..<s.canonCount { w[c] = s.weight[s.reps[c]] }
        return w
    }

    private func cfr(_ n: Int, _ p: Int, _ selfReach: [Float], _ oppReach: [Float], _ pos: Float, _ neg: Float, _ d: Float) -> [Float] {
        let node = nodes[n]
        guard case .decision(let actor) = node.kind else { return terminalValues(node, player: p, oppReach: oppReach) }
        let k = node.actions.count
        let sigma = currentStrategy(node, player: actor)
        let np = sides[actor].padded
        if actor != p {
            var value = [Float](repeating: 0, count: sides[p].padded)
            for a in 0..<k {
                var reach = oppReach
                for h in 0..<np { reach[h] *= sigma[a * np + h] }
                let v = cfr(node.children[a], p, selfReach, reach, pos, neg, d)
                for h in 0..<value.count { value[h] += v[h] }
            }
            return value
        }
        var actionValues: [[Float]] = []
        var value = [Float](repeating: 0, count: np)
        for a in 0..<k {
            var reach = selfReach
            for h in 0..<np { reach[h] *= sigma[a * np + h] }
            let v = cfr(node.children[a], p, reach, oppReach, pos, neg, d)
            actionValues.append(v)
            addProduct(&value, sigma, a * np, v)
        }
        // DCFR regret and strategy-sum updates, eight hands at a time.
        regrets.withUnsafeMutableBufferPointer { R in
            strategySum.withUnsafeMutableBufferPointer { S in
                let rBase = UnsafeMutableRawPointer(R.baseAddress! + node.offset)
                let sBase = UnsafeMutableRawPointer(S.baseAddress! + node.offset)
                let posV = V8(repeating: pos), negV = V8(repeating: neg), dV = V8(repeating: d), zero = V8()
                value.withUnsafeBytes { vB in
                    selfReach.withUnsafeBytes { reB in
                        sigma.withUnsafeBytes { sgB in
                            for a in 0..<k {
                                actionValues[a].withUnsafeBytes { avB in
                                    for l in stride(from: 0, to: np, by: 8) {
                                        let o = (a * np + l) * 4
                                        let old = rBase.loadUnaligned(fromByteOffset: o, as: V8.self)
                                        let inst = avB.loadUnaligned(fromByteOffset: l * 4, as: V8.self) - vB.loadUnaligned(fromByteOffset: l * 4, as: V8.self)
                                        rBase.storeBytes(of: old * negV.replacing(with: posV, where: old .> zero) + inst, toByteOffset: o, as: V8.self)
                                        let contrib = reB.loadUnaligned(fromByteOffset: l * 4, as: V8.self) * sgB.loadUnaligned(fromByteOffset: o, as: V8.self)
                                        sBase.storeBytes(of: (sBase.loadUnaligned(fromByteOffset: o, as: V8.self) + contrib) * dV, toByteOffset: o, as: V8.self)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        return value
    }

    /// value[h] += strategy[offset + h] * v[h]
    private func addProduct(_ value: inout [Float], _ strategy: [Float], _ offset: Int, _ v: [Float]) {
        let count = value.count
        value.withUnsafeMutableBytes { out in
            strategy.withUnsafeBytes { s in
                v.withUnsafeBytes { vb in
                    for l in stride(from: 0, to: count, by: 8) {
                        let cur = out.loadUnaligned(fromByteOffset: l * 4, as: V8.self)
                        let next = cur + s.loadUnaligned(fromByteOffset: (offset + l) * 4, as: V8.self) * vb.loadUnaligned(fromByteOffset: l * 4, as: V8.self)
                        out.storeBytes(of: next, toByteOffset: l * 4, as: V8.self)
                    }
                }
            }
        }
    }

    // MARK: Evaluation

    /// Optional fixed strategies (node index -> one row of `padded` per action, in the acting
    /// player's canonical order) that replace the average strategy, for node locking.
    public typealias Overrides = [Int: [Float]]

    private func strategy(at n: Int, _ overrides: Overrides) -> [Float] {
        if let o = overrides[n] { return o }
        guard case .decision(let actor) = nodes[n].kind else { return [] }
        return averageStrategy(nodes[n], player: actor)
    }

    /// Values for player p's canonical hands. `bestResponse`: p maximises at its nodes.
    private func evaluate(_ n: Int, _ p: Int, _ oppReach: [Float], bestResponse: Bool, _ overrides: Overrides) -> [Float] {
        let node = nodes[n]
        guard case .decision(let actor) = node.kind else { return terminalValues(node, player: p, oppReach: oppReach) }
        let sigma = strategy(at: n, overrides)
        let np = sides[actor].padded, k = node.actions.count
        if actor != p {
            var value = [Float](repeating: 0, count: sides[p].padded)
            for a in 0..<k {
                var reach = oppReach
                for h in 0..<np { reach[h] *= sigma[a * np + h] }
                let v = evaluate(node.children[a], p, reach, bestResponse: bestResponse, overrides)
                for h in 0..<value.count { value[h] += v[h] }
            }
            return value
        }
        var value = [Float](repeating: bestResponse ? -.greatestFiniteMagnitude : 0, count: np)
        for a in 0..<k {
            let v = evaluate(node.children[a], p, oppReach, bestResponse: bestResponse, overrides)
            if bestResponse { for h in 0..<np { value[h] = max(value[h], v[h]) } }
            else { addProduct(&value, sigma, a * np, v) }
        }
        return value
    }

    /// Weighted total of per-hand values: expected value per dealt pair of hands.
    private func total(_ values: [Float], player p: Int) -> Double {
        let s = sides[p]
        var sum = 0.0
        for c in 0..<s.canonCount { sum += Double(values[c]) * Double(s.weight[s.reps[c]]) * Double(s.multiplicity[c]) }
        return sum / pairMass
    }

    /// Expected value (pot-share convention, chips) of each player under the average strategies.
    public func expectedValues(overrides: Overrides = [:]) -> (oop: Double, ip: Double) {
        (total(evaluate(root, 0, canonicalWeights(1), bestResponse: false, overrides), player: 0),
         total(evaluate(root, 1, canonicalWeights(0), bestResponse: false, overrides), player: 1))
    }

    /// Exploitability of the average strategies as a percentage of the starting pot: the mean of
    /// what each player's best response gains (zero exactly at a Nash equilibrium).
    public func exploitability() -> Double {
        let br0 = total(evaluate(root, 0, canonicalWeights(1), bestResponse: true, [:]), player: 0)
        let br1 = total(evaluate(root, 1, canonicalWeights(0), bestResponse: true, [:]), player: 1)
        return max(0, (br0 + br1) / 2) / spot.pot * 100
    }

    public struct SolveResult: Sendable {
        public let iterations: Int
        public let exploitability: Double   // % of pot
        public let solveSeconds: Double      // excludes exploitability checks
        public let curve: [(iteration: Int, exploitability: Double)]
    }

    /// Iterates until exploitability is below `target` (% of pot) or `maxIterations` is reached.
    @discardableResult
    public func solve(targetExploitability target: Double = 0.3, maxIterations: Int = 2000, checkEvery: Int = 25,
                      progress: ((Int, Double) -> Bool)? = nil) -> SolveResult {
        let clock = ContinuousClock()
        var time = Duration.zero
        var curve: [(Int, Double)] = []
        var e = Double.infinity
        while iteration < maxIterations {
            let t0 = clock.now
            iterate(min(checkEvery, maxIterations - iteration))
            time += clock.now - t0
            e = exploitability()
            curve.append((iteration, e))
            if let progress, !progress(iteration, e) { break }
            if e <= target { break }
        }
        let s = Double(time.components.seconds) + Double(time.components.attoseconds) * 1e-18
        return SolveResult(iterations: iteration, exploitability: e, solveSeconds: s, curve: curve.map { (iteration: $0.0, exploitability: $0.1) })
    }

    // MARK: Queries

    /// Canonical index of a hand for player p, or nil if it isn't in the range.
    public func handIndex(_ hand: HoleCards, player p: Int) -> Int? {
        let i = sides[p].comboIndex[Int(hand.high.rawValue) * 52 + Int(hand.low.rawValue)]
        return i >= 0 ? sides[p].canon[i] : nil
    }

    public func hands(player p: Int) -> [HoleCards] {
        sides[p].cards.map { HoleCards(Card(rawValue: $0.0), Card(rawValue: $0.1)) }
    }

    /// Average-strategy frequencies of each action for one hand at a decision node.
    public func frequencies(at n: Int, hand: HoleCards) -> [Double]? {
        guard case .decision(let actor) = nodes[n].kind, let c = handIndex(hand, player: actor) else { return nil }
        let s = averageStrategy(nodes[n], player: actor), np = sides[actor].padded
        return nodes[n].actions.indices.map { Double(s[$0 * np + c]) }
    }

    /// Follows action indices from the root.
    public func node(path: [Int]) -> Int {
        path.reduce(root) { nodes[$0].children[$1] }
    }

    /// Per-hand EV of each action at decision node `n`, for the acting player, given that the
    /// hand reached the node: the opponent's reach comes from the average strategies (or
    /// `overrides`) along the path. EVs use the pot-share convention plus pot/2, i.e. the
    /// chips the hand wins back from the starting pot and both players' river bets.
    public func actionEVs(at n: Int, path: [Int], hand: HoleCards, overrides: Overrides = [:]) -> [Double]? {
        guard case .decision(let actor) = nodes[n].kind, let c = handIndex(hand, player: actor) else { return nil }
        let opp = 1 - actor
        var reach = canonicalWeights(opp)
        var cur = root
        for a in path {
            if case .decision(let who) = nodes[cur].kind, who == opp {
                let s = strategy(at: cur, overrides), np = sides[opp].padded
                for h in 0..<np { reach[h] *= s[a * np + h] }
            }
            cur = nodes[cur].children[a]
        }
        precondition(cur == n, "path does not lead to node")
        // Normalise by the opponent mass compatible with this hand.
        let full = expand(reach, side: opp)
        let (a, b) = sides[actor].cards[sides[actor].reps[c]]
        var mass: Float = 0
        for j in 0..<sides[opp].count {
            let (x, y) = sides[opp].cards[j]
            if x != a && x != b && y != a && y != b { mass += full[j] }
        }
        guard mass > 0 else { return nil }
        return nodes[n].children.map { child in
            let v = evaluate(child, actor, reach, bestResponse: false, overrides)
            // Values are relative to the start of the river; add back what's already in.
            return Double(v[c] / mass) + spot.pot / 2
        }
    }

    /// The acting player's whole-range action frequencies at the node reached by `path`,
    /// weighting each hand by how often it gets there.
    public func rangeFrequencies(path: [Int]) -> [Double] {
        let n = node(path: path)
        guard case .decision(let actor) = nodes[n].kind else { return [] }
        var reach = canonicalWeights(actor)
        var cur = root
        for a in path {
            if case .decision(let who) = nodes[cur].kind, who == actor {
                let s = averageStrategy(nodes[cur], player: actor), np = sides[actor].padded
                for h in 0..<np { reach[h] *= s[a * np + h] }
            }
            cur = nodes[cur].children[a]
        }
        let s = averageStrategy(nodes[n], player: actor), np = sides[actor].padded
        var out = [Double](repeating: 0, count: nodes[n].actions.count)
        var total = 0.0
        for c in 0..<sides[actor].canonCount {
            let w = Double(reach[c]) * Double(sides[actor].multiplicity[c])
            total += w
            for a in out.indices { out[a] += w * Double(s[a * np + c]) }
        }
        return total > 0 ? out.map { $0 / total } : out
    }

    /// Exact river equity of each range against the other (ties split).
    public func rangeEquity() -> (oop: Double, ip: Double) {
        var win = 0.0, tie = 0.0
        for i in 0..<sides[0].count {
            let (a, b) = sides[0].cards[i]
            for j in 0..<sides[1].count {
                let (c, d) = sides[1].cards[j]
                guard a != c && a != d && b != c && b != d else { continue }
                let w = Double(sides[0].weight[i]) * Double(sides[1].weight[j])
                if sides[0].strength[i] > sides[1].strength[j] { win += w } else if sides[0].strength[i] == sides[1].strength[j] { tie += w }
            }
        }
        let e = (win + tie / 2) / pairMass
        return (e, 1 - e)
    }

    /// Builds an override for player p at node n from a per-hand function of action frequencies.
    public func override(at n: Int, _ frequencies: (HoleCards) -> [Double]) -> [Float] {
        guard case .decision(let actor) = nodes[n].kind else { return [] }
        let s = sides[actor], np = s.padded, k = nodes[n].actions.count
        var out = [Float](repeating: 0, count: np * k)
        for c in 0..<s.canonCount {
            let (a, b) = s.cards[s.reps[c]]
            let f = frequencies(HoleCards(Card(rawValue: a), Card(rawValue: b)))
            for x in 0..<k { out[x * np + c] = Float(f[x]) }
        }
        return out
    }

    /// Rank of a hand's strength within player p's range (0 = weakest, 1 = strongest), weighted.
    public func strengthPercentile(_ hand: HoleCards, player p: Int) -> Double? {
        let s = sides[p]
        let i0 = s.comboIndex[Int(hand.high.rawValue) * 52 + Int(hand.low.rawValue)]
        guard i0 >= 0 else { return nil }
        let total = s.weight.reduce(0, +)
        var below: Float = 0
        for j in 0..<s.count where s.strength[j] < s.strength[i0] { below += s.weight[j] }
        var equal: Float = 0
        for j in 0..<s.count where s.strength[j] == s.strength[i0] { equal += s.weight[j] }
        return Double((below + equal / 2) / total)
    }
}
