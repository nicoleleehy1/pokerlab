/// Small two-player zero-sum games in extensive form (Kuhn poker, the clairvoyance game),
/// solved with tabular CFR and measured with an exact best response. Payoffs are player 0's;
/// player 1 receives the negative.
public struct ToyGame: Sendable {
    public struct InfoSet: Sendable, Hashable {
        public let name: String
        public let player: Int
        public let actions: [String]
        /// Offset of this infoset's first action in the flat regret/strategy arrays.
        public let offset: Int
    }

    enum Node: Sendable {
        case terminal(Double)
        case chance([(Double, Int)])
        case decision(infoset: Int, children: [Int])
    }

    public let name: String
    public private(set) var infosets: [InfoSet] = []
    var nodes: [Node] = []
    var depth: [Int] = []
    var actionCount = 0
    private var infosetIndex: [String: Int] = [:]

    init(name: String) { self.name = name }

    // MARK: Building

    final class Builder {
        var game: ToyGame
        init(_ name: String) { game = ToyGame(name: name) }

        func terminal(_ payoff: Double) -> ToyNode { ToyNode { b, d in b.add(.terminal(payoff), depth: d) } }

        func chance(_ outcomes: [(Double, ToyNode)]) -> ToyNode {
            ToyNode { b, d in
                let kids = outcomes.map { ($0.0, $0.1.build(b, d + 1)) }
                return b.add(.chance(kids), depth: d)
            }
        }

        func decision(_ infoset: String, player: Int, _ actions: [(String, ToyNode)]) -> ToyNode {
            ToyNode { b, d in
                let set = b.infoset(infoset, player: player, actions: actions.map(\.0))
                let kids = actions.map { $0.1.build(b, d + 1) }
                return b.add(.decision(infoset: set, children: kids), depth: d)
            }
        }

        func add(_ node: Node, depth: Int) -> Int {
            game.nodes.append(node)
            game.depth.append(depth)
            return game.nodes.count - 1
        }

        func infoset(_ name: String, player: Int, actions: [String]) -> Int {
            if let i = game.infosetIndex[name] {
                precondition(game.infosets[i].actions == actions && game.infosets[i].player == player, "inconsistent infoset \(name)")
                return i
            }
            game.infosets.append(InfoSet(name: name, player: player, actions: actions, offset: game.actionCount))
            game.actionCount += actions.count
            game.infosetIndex[name] = game.infosets.count - 1
            return game.infosets.count - 1
        }

        func finish(_ root: ToyNode) -> ToyGame {
            let r = root.build(self, 0)
            game.root = r
            return game
        }
    }

    /// A deferred subtree (built depth-first when the game is finished).
    struct ToyNode {
        let build: (Builder, Int) -> Int
    }

    var root = 0

    // MARK: Games

    /// Kuhn poker: a three-card deck (J, Q, K), one-chip antes, one bet of one chip. Player 0
    /// acts first. The game value for player 0 is -1/18.
    public static let kuhn: ToyGame = {
        let b = Builder("Kuhn poker")
        let names = ["J", "Q", "K"]
        var deals: [(Double, ToyNode)] = []
        for c0 in 0..<3 { for c1 in 0..<3 where c1 != c0 {
            let win = c0 > c1 ? 1.0 : -1.0
            let p0 = names[c0], p1 = names[c1]
            let node = b.decision("\(p0) · first to act", player: 0, [
                ("Check", b.decision("\(p1) · after a check", player: 1, [
                    ("Check", b.terminal(win)),
                    ("Bet", b.decision("\(p0) · check, facing a bet", player: 0, [
                        ("Fold", b.terminal(-1)),
                        ("Call", b.terminal(2 * win)),
                    ])),
                ])),
                ("Bet", b.decision("\(p1) · facing a bet", player: 1, [
                    ("Fold", b.terminal(1)),
                    ("Call", b.terminal(2 * win)),
                ])),
            ])
            deals.append((1.0 / 6, node))
        } }
        return b.finish(b.chance(deals))
    }()

    public static let kuhnValue = -1.0 / 18

    /// The clairvoyance game: a pot of 1 is already in the middle. Player 0 knows whether they
    /// hold the nuts or air (half the time each) and may bet `bet` (a fraction of the pot) or
    /// check; player 1 holds a bluff-catcher and calls or folds. Checks go to showdown.
    /// At equilibrium player 0 bluffs s/(1+s) of their air, player 1 calls 1/(1+s), and player
    /// 0's value is (1 + 2s) / (2 (1 + s)).
    public static func clairvoyance(bet s: Double) -> ToyGame {
        let b = Builder("Clairvoyance game")
        func hand(_ name: String, nuts: Bool) -> ToyNode {
            b.decision("Bettor · \(name)", player: 0, [
                ("Check", b.terminal(nuts ? 1 : 0)),
                ("Bet", b.decision("Caller · facing a bet", player: 1, [
                    ("Fold", b.terminal(1)),
                    ("Call", b.terminal(nuts ? 1 + s : -s)),
                ])),
            ])
        }
        return b.finish(b.chance([(0.5, hand("nuts", nuts: true)), (0.5, hand("air", nuts: false))]))
    }

    public static func clairvoyanceValue(bet s: Double) -> Double { (1 + 2 * s) / (2 * (1 + s)) }

    // MARK: Evaluation

    /// Player 0's expected payoff when both follow `strategy` (flat, per infoset action).
    public func value(_ strategy: [Double]) -> Double { evaluate(root, strategy) }

    private func evaluate(_ n: Int, _ s: [Double]) -> Double {
        switch nodes[n] {
        case .terminal(let u): return u
        case .chance(let kids): return kids.reduce(0) { $0 + $1.0 * evaluate($1.1, s) }
        case .decision(let i, let kids):
            let o = infosets[i].offset
            return kids.indices.reduce(0) { $0 + s[o + $1] * evaluate(kids[$1], s) }
        }
    }

    /// Exploitability: the average of what each player's best response gains against the
    /// other's strategy (zero exactly at a Nash equilibrium), in chips per hand.
    public func exploitability(_ strategy: [Double]) -> Double {
        (bestResponseValue(player: 0, against: strategy) + bestResponseValue(player: 1, against: strategy)) / 2
    }

    /// The value (to `player`) of a best response to the other player's part of `strategy`.
    public func bestResponseValue(player p: Int, against s: [Double]) -> Double {
        // Opponent-and-chance reach of every node.
        var reach = [Double](repeating: 0, count: nodes.count)
        func forward(_ n: Int, _ r: Double) {
            reach[n] = r
            switch nodes[n] {
            case .terminal: break
            case .chance(let kids): for (prob, c) in kids { forward(c, r * prob) }
            case .decision(let i, let kids):
                let set = infosets[i]
                for (a, c) in kids.enumerated() { forward(c, set.player == p ? r : r * s[set.offset + a]) }
            }
        }
        forward(root, 1)

        // Fix best-response actions deepest infoset first (perfect recall: an infoset's
        // subtrees only contain deeper infosets of the same player).
        var choice = [Int?](repeating: nil, count: infosets.count)
        var members = [[Int]](repeating: [], count: infosets.count)
        for (n, node) in nodes.enumerated() { if case .decision(let i, _) = node, infosets[i].player == p { members[i].append(n) } }
        func v(_ n: Int) -> Double {
            switch nodes[n] {
            case .terminal(let u): return p == 0 ? u : -u
            case .chance(let kids): return kids.reduce(0) { $0 + $1.0 * v($1.1) }
            case .decision(let i, let kids):
                let set = infosets[i]
                if set.player == p { return v(kids[choice[i]!]) }
                return kids.indices.reduce(0) { $0 + s[set.offset + $1] * v(kids[$1]) }
            }
        }
        let order = infosets.indices.filter { infosets[$0].player == p }
            .sorted { depth[members[$0][0]] > depth[members[$1][0]] }
        for i in order {
            var best = 0, bestValue = -Double.infinity
            for a in infosets[i].actions.indices {
                var total = 0.0
                for n in members[i] {
                    guard case .decision(_, let kids) = nodes[n] else { continue }
                    total += reach[n] * v(kids[a])
                }
                if total > bestValue + 1e-15 { bestValue = total; best = a }
            }
            choice[i] = best
        }
        return v(root)
    }
}

/// Tabular CFR with alternating updates. `vanilla` is Zinkevich et al.; `cfrPlus` floors
/// regrets at zero and averages linearly; `dcfr` is Discounted CFR (Brown & Sandholm 2019).
public struct ToyCFR: Sendable {
    public enum Variant: Hashable, Sendable {
        case vanilla, cfrPlus
        case dcfr(alpha: Double, beta: Double, gamma: Double)
        public static let dcfrDefault = Variant.dcfr(alpha: 1.5, beta: 0, gamma: 2)

        public var name: String {
            switch self {
            case .vanilla: "CFR"
            case .cfrPlus: "CFR+"
            case .dcfr(let a, let b, let g): "DCFR (\(fmt(a)), \(fmt(b)), \(fmt(g)))"
            }
        }
        private func fmt(_ x: Double) -> String { x == x.rounded() ? String(Int(x)) : String(x) }
    }

    public let game: ToyGame
    public let variant: Variant
    public private(set) var iteration = 0
    var regret: [Double]
    var strategySum: [Double]

    public init(game: ToyGame, variant: Variant) {
        self.game = game
        self.variant = variant
        regret = Array(repeating: 0, count: game.actionCount)
        strategySum = Array(repeating: 0, count: game.actionCount)
    }

    /// Current (regret-matching) strategy.
    public var current: [Double] { matched(regret) }

    /// Average strategy: the one that converges to equilibrium.
    public var average: [Double] {
        var out = [Double](repeating: 0, count: game.actionCount)
        for set in game.infosets {
            let k = set.actions.count, o = set.offset
            let total = (0..<k).reduce(0) { $0 + strategySum[o + $1] }
            for a in 0..<k { out[o + a] = total > 0 ? strategySum[o + a] / total : 1 / Double(k) }
        }
        return out
    }

    func matched(_ r: [Double]) -> [Double] {
        var out = [Double](repeating: 0, count: r.count)
        for set in game.infosets {
            let k = set.actions.count, o = set.offset
            let pos = (0..<k).reduce(0) { $0 + max(r[o + $1], 0) }
            for a in 0..<k { out[o + a] = pos > 0 ? max(r[o + a], 0) / pos : 1 / Double(k) }
        }
        return out
    }

    public mutating func run(iterations: Int) {
        for _ in 0..<iterations { step() }
    }

    mutating func step() {
        iteration += 1
        let t = Double(iteration)
        for p in 0..<2 {
            let sigma = matched(regret)
            var delta = [Double](repeating: 0, count: game.actionCount)
            let weight: Double = switch variant {
            case .vanilla: 1
            case .cfrPlus: t
            case .dcfr: 1
            }
            _ = walk(game.root, p, 1, 1, sigma, &delta, weight)
            switch variant {
            case .vanilla:
                for i in regret.indices { regret[i] += delta[i] }
            case .cfrPlus:
                for i in regret.indices { regret[i] = max(regret[i] + delta[i], 0) }
            case .dcfr(let alpha, let beta, _):
                let pos = pow(t, alpha) / (pow(t, alpha) + 1), neg = pow(t, beta) / (pow(t, beta) + 1)
                for set in game.infosets where set.player == p {
                    for i in set.offset..<(set.offset + set.actions.count) {
                        regret[i] = regret[i] * (regret[i] > 0 ? pos : neg) + delta[i]
                    }
                }
            }
        }
        if case .dcfr(_, _, let gamma) = variant {
            // Discount earlier contributions to the average strategy by (t / (t + 1))^gamma.
            let d = pow(t / (t + 1), gamma)
            for i in strategySum.indices { strategySum[i] *= d }
        }
    }

    /// Returns player `p`'s counterfactual value; accumulates p's regrets in `delta` and p's
    /// average-strategy contributions in `strategySum`.
    private mutating func walk(_ n: Int, _ p: Int, _ reachP: Double, _ reachO: Double, _ sigma: [Double],
                               _ delta: inout [Double], _ weight: Double) -> Double {
        switch game.nodes[n] {
        case .terminal(let u):
            return p == 0 ? u : -u
        case .chance(let kids):
            var v = 0.0
            for (prob, c) in kids { v += prob * walk(c, p, reachP, reachO * prob, sigma, &delta, weight) }
            return v
        case .decision(let i, let kids):
            let set = game.infosets[i], o = set.offset
            if set.player != p {
                var v = 0.0
                for (a, c) in kids.enumerated() where sigma[o + a] > 0 {
                    v += sigma[o + a] * walk(c, p, reachP, reachO * sigma[o + a], sigma, &delta, weight)
                }
                return v
            }
            var values = [Double](repeating: 0, count: kids.count)
            var v = 0.0
            for (a, c) in kids.enumerated() {
                values[a] = walk(c, p, reachP * sigma[o + a], reachO, sigma, &delta, weight)
                v += sigma[o + a] * values[a]
            }
            for a in kids.indices {
                delta[o + a] += reachO * (values[a] - v)
                strategySum[o + a] += weight * reachP * sigma[o + a]
            }
            return v
        }
    }
}

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
