import Foundation
import PokerCore

/// A postflop spot on the flop, turn or river. Player 0 is out of position.
public struct StreetSpot: Hashable, Sendable {
    public var board: [Card]
    public var pot: Double
    public var stack: Double
    public var ranges: [HandRange]
    /// The same bet-size abstraction is used on every street.
    public var config: RiverTreeConfig

    public init(board: [Card], pot: Double, stack: Double, oop: HandRange, ip: HandRange, config: RiverTreeConfig = .init()) {
        precondition((3...5).contains(board.count), "a postflop spot needs 3, 4 or 5 board cards")
        self.board = board; self.pot = pot; self.stack = stack; ranges = [oop, ip]; self.config = config
    }
}

/// Multi-street postflop solver (flop, turn or river) with Discounted CFR (1.5, 0, 2).
///
/// Between streets a chance node deals each card not on the board with equal weight; hands
/// that contain the dealt card get zero reach below it, so card removal is exact. Showdowns use
/// the same O(n) sort-and-sweep as `RiverSolver`, with hand strengths precomputed once per
/// final board. Exploitability comes from an exact best response.
///
/// Memory grows with the number of runouts: a turn with full ranges is a few MB, but a
/// full-range flop with even one bet size needs over a gigabyte, so flop solves are meant
/// for narrowed ranges (and a precomputed library for the rest). No suit isomorphism here.
public final class StreetSolver: @unchecked Sendable {
    public struct Node: Sendable {
        public enum Kind: Hashable, Sendable { case decision(player: Int), fold(folder: Int), showdown, chance }
        public let kind: Kind
        public let contributions: (Double, Double)
        public let board: UInt64                 // card masks (Card.mask) of every board card so far
        public let actions: [RiverSolver.Action]
        public let children: [Int]
        public let dealt: [UInt8]                // chance nodes: the card dealt to reach each child
        let offset: Int
    }

    struct Side {
        var cards: [(UInt8, UInt8)] = []
        var masks: [UInt64] = []
        var weight: [Float] = []
        var comboIndex = [Int](repeating: -1, count: 52 * 52)
        var count: Int { cards.count }
    }

    /// Strengths and sorted orders of both sides on one five-card board.
    struct Showdown {
        var strength: [[UInt16]]
        var sorted: [[Int]]
    }

    public let spot: StreetSpot
    public private(set) var nodes: [Node] = []
    public let root = 0
    var sides = [Side(), Side()]
    var regrets: [Float] = []
    var strategySum: [Float] = []
    var showdowns: [UInt64: Showdown] = [:]
    public private(set) var iteration = 0
    let pairMass: Double

    public init(spot: StreetSpot) throws {
        self.spot = spot
        let boardSet = CardSet(spot.board)
        for p in 0..<2 {
            let combos = spot.ranges[p].removing(boardSet).combos
            guard !combos.isEmpty else { throw RiverSolverError.emptyRange(player: p) }
            var s = Side()
            for c in combos {
                let a = c.cards.high.rawValue, b = c.cards.low.rawValue
                s.comboIndex[Int(a) * 52 + Int(b)] = s.count
                s.comboIndex[Int(b) * 52 + Int(a)] = s.count
                s.cards.append((a, b)); s.masks.append(c.cards.mask); s.weight.append(Float(c.weight))
            }
            sides[p] = s
        }
        var mass = 0.0
        for i in 0..<sides[0].count {
            for j in 0..<sides[1].count where sides[0].masks[i] & sides[1].masks[j] == 0 {
                mass += Double(sides[0].weight[i]) * Double(sides[1].weight[j])
            }
        }
        guard mass > 0 else { throw RiverSolverError.noCompatibleHands }
        pairMass = mass
        var storage = 0
        _ = streetStart(board: boardSet.rawValue, c: (0, 0), &storage)
        regrets = Array(repeating: 0, count: storage)
        strategySum = Array(repeating: 0, count: storage)
        precomputeShowdowns()
    }

    // MARK: Tree

    private func cardCount(_ board: UInt64) -> Int { board.nonzeroBitCount }

    /// Start of a street (or a runout when both players are all-in).
    private func streetStart(board: UInt64, c: (Double, Double), _ storage: inout Int) -> Int {
        let allIn = c.0 >= spot.stack && c.1 >= spot.stack
        if allIn { return cardCount(board) == 5 ? leaf(.showdown, c, board) : chance(board: board, c: c, &storage) }
        return decision(player: 0, c: c, bets: 0, board: board, &storage)
    }

    private func streetEnd(board: UInt64, c: (Double, Double), _ storage: inout Int) -> Int {
        cardCount(board) == 5 ? leaf(.showdown, c, board) : chance(board: board, c: c, &storage)
    }

    private func chance(board: UInt64, c: (Double, Double), _ storage: inout Int) -> Int {
        let index = nodes.count
        nodes.append(Node(kind: .chance, contributions: c, board: board, actions: [], children: [], dealt: [], offset: 0))
        var kids: [Int] = [], dealt: [UInt8] = []
        for raw in 0..<52 {
            let card = Card(rawValue: UInt8(raw))
            guard board & card.mask == 0 else { continue }
            dealt.append(UInt8(raw))
            kids.append(streetStart(board: board | card.mask, c: c, &storage))
        }
        nodes[index] = Node(kind: .chance, contributions: c, board: board, actions: [], children: kids, dealt: dealt, offset: 0)
        return index
    }

    private func leaf(_ kind: Node.Kind, _ c: (Double, Double), _ board: UInt64) -> Int {
        nodes.append(Node(kind: kind, contributions: c, board: board, actions: [], children: [], dealt: [], offset: 0))
        return nodes.count - 1
    }

    private func decision(player: Int, c: (Double, Double), bets: Int, board: UInt64, _ storage: inout Int) -> Int {
        let cfg = spot.config, stack = spot.stack
        let mine = player == 0 ? c.0 : c.1, theirs = player == 0 ? c.1 : c.0
        let pot = spot.pot + c.0 + c.1
        var actions: [RiverSolver.Action] = []
        func add(_ kind: RiverSolver.ActionKind, _ to: Double, _ label: String) {
            if !actions.contains(where: { $0.kind != .fold && abs($0.to - to) < 1e-9 }) { actions.append(.init(kind: kind, to: to, label: label)) }
        }
        if mine == theirs {
            add(.check, mine, "Check")
            let canBet = player == 0 ? cfg.oopCanBet : cfg.ipCanBet
            if canBet && mine < stack {
                for s in cfg.betSizes {
                    let to = min(stack, mine + s * pot)
                    add(to >= stack ? .allIn : .bet, to, to >= stack ? "All-in" : "Bet \(Int((s * 100).rounded()))%")
                }
                if cfg.allowAllIn { add(.allIn, stack, "All-in") }
            }
        } else {
            actions.append(.init(kind: .fold, to: mine, label: "Fold"))
            add(.call, theirs, "Call")
            if bets < cfg.maxBets && theirs < stack {
                for s in cfg.raiseSizes {
                    let to = min(stack, theirs + s * (spot.pot + 2 * theirs))
                    add(to >= stack ? .allIn : .raise, to, to >= stack ? "All-in" : "Raise")
                }
                if cfg.allowAllIn { add(.allIn, stack, "All-in") }
            }
        }
        let index = nodes.count
        nodes.append(Node(kind: .decision(player: player), contributions: c, board: board, actions: actions, children: [], dealt: [], offset: storage))
        storage += actions.count * sides[player].count
        var kids: [Int] = []
        for a in actions {
            let nc = player == 0 ? (a.to, c.1) : (c.0, a.to)
            switch a.kind {
            case .fold: kids.append(leaf(.fold(folder: player), c, board))
            case .call: kids.append(streetEnd(board: board, c: nc, &storage))
            case .check:
                if player == 0 { kids.append(decision(player: 1, c: nc, bets: bets, board: board, &storage)) }
                else { kids.append(streetEnd(board: board, c: nc, &storage)) }
            case .bet, .raise, .allIn:
                kids.append(decision(player: 1 - player, c: nc, bets: bets + 1, board: board, &storage))
            }
        }
        let n = nodes[index]
        nodes[index] = Node(kind: n.kind, contributions: c, board: board, actions: actions, children: kids, dealt: [], offset: n.offset)
        return index
    }

    private func precomputeShowdowns() {
        let eval = HandEvaluator.shared
        var boards = Set<UInt64>()
        for n in nodes where n.kind == .showdown { boards.insert(n.board) }
        for b in boards {
            let key = eval.key(for: CardSet(rawValue: b))
            var sd = Showdown(strength: [[], []], sorted: [[], []])
            for p in 0..<2 {
                let s = sides[p]
                sd.strength[p] = (0..<s.count).map { i in
                    eval.evaluate(eval.adding(Card(rawValue: s.cards[i].1), to: eval.adding(Card(rawValue: s.cards[i].0), to: key))).rawValue
                }
                let st = sd.strength[p]
                sd.sorted[p] = (0..<s.count).sorted { st[$0] < st[$1] }
            }
            showdowns[b] = sd
        }
    }

    // MARK: Sizes

    public var handCounts: (oop: Int, ip: Int) { (sides[0].count, sides[1].count) }
    public var decisionNodeCount: Int { nodes.filter { if case .decision = $0.kind { true } else { false } }.count }
    public var chanceNodeCount: Int { nodes.filter { $0.kind == .chance }.count }
    public var storageBytes: Int { (regrets.count + strategySum.count) * MemoryLayout<Float>.stride }

    // MARK: Values

    func terminalValues(_ node: Node, player p: Int, oppReach full: [Float]) -> [Float] {
        let hero = sides[p], opp = sides[1 - p]
        var out = [Float](repeating: 0, count: hero.count)
        let half = spot.pot / 2
        switch node.kind {
        case .fold(let folder):
            let paid = Float(half + (folder == 0 ? node.contributions.0 : node.contributions.1))
            let payoff = folder == p ? -paid : paid
            var total: Float = 0
            var perCard = [Float](repeating: 0, count: 52)
            for j in 0..<opp.count {
                let r = full[j]
                guard r != 0 else { continue }
                total += r; perCard[Int(opp.cards[j].0)] += r; perCard[Int(opp.cards[j].1)] += r
            }
            for i in 0..<hero.count {
                let (a, b) = hero.cards[i]
                var mass = total - perCard[Int(a)] - perCard[Int(b)]
                let same = opp.comboIndex[Int(a) * 52 + Int(b)]
                if same >= 0 { mass += full[same] }
                out[i] = payoff * mass
            }
        case .showdown:
            let sd = showdowns[node.board]!
            let hs = sd.strength[p], os = sd.strength[1 - p]
            let hOrder = sd.sorted[p], oOrder = sd.sorted[1 - p]
            let stake = Float(half + node.contributions.0)
            var perCard = [Float](repeating: 0, count: 52)
            var win = [Float](repeating: 0, count: hero.count)
            var acc: Float = 0, j = 0
            for i in hOrder {
                while j < opp.count, os[oOrder[j]] < hs[i] {
                    let k = oOrder[j], r = full[k]
                    acc += r; perCard[Int(opp.cards[k].0)] += r; perCard[Int(opp.cards[k].1)] += r
                    j += 1
                }
                win[i] = acc - perCard[Int(hero.cards[i].0)] - perCard[Int(hero.cards[i].1)]
            }
            for x in 0..<52 { perCard[x] = 0 }
            acc = 0; j = opp.count - 1
            for i in hOrder.reversed() {
                while j >= 0, os[oOrder[j]] > hs[i] {
                    let k = oOrder[j], r = full[k]
                    acc += r; perCard[Int(opp.cards[k].0)] += r; perCard[Int(opp.cards[k].1)] += r
                    j -= 1
                }
                let lose = acc - perCard[Int(hero.cards[i].0)] - perCard[Int(hero.cards[i].1)]
                out[i] = stake * (win[i] - lose)
            }
        case .decision, .chance:
            preconditionFailure("not a terminal")
        }
        return out
    }

    /// Weight of each chance outcome: every card not on the board or in either hand is equally likely.
    private func chanceWeight(_ node: Node) -> Float { 1 / Float(52 - cardCount(node.board) - 4) }

    /// Zeroes the entries of hands that contain `card`.
    private func mask(_ v: inout [Float], side p: Int, card: UInt8) {
        let m = Card(rawValue: card).mask
        for i in 0..<sides[p].count where sides[p].masks[i] & m != 0 { v[i] = 0 }
    }

    func currentStrategy(_ node: Node, player p: Int) -> [Float] {
        let n = sides[p].count, k = node.actions.count
        var out = [Float](repeating: 0, count: n * k)
        for h in 0..<n {
            var sum: Float = 0
            for a in 0..<k { sum += max(regrets[node.offset + a * n + h], 0) }
            for a in 0..<k { out[a * n + h] = sum > 0 ? max(regrets[node.offset + a * n + h], 0) / sum : 1 / Float(k) }
        }
        return out
    }

    func averageStrategy(_ node: Node, player p: Int) -> [Float] {
        let n = sides[p].count, k = node.actions.count
        var out = [Float](repeating: 0, count: n * k)
        for h in 0..<n {
            var sum: Float = 0
            for a in 0..<k { sum += strategySum[node.offset + a * n + h] }
            for a in 0..<k { out[a * n + h] = sum > 0 ? strategySum[node.offset + a * n + h] / sum : 1 / Float(k) }
        }
        return out
    }

    // MARK: DCFR

    public func iterate(_ count: Int) {
        for _ in 0..<count {
            iteration += 1
            let t = Double(iteration)
            let ta = pow(t, 1.5)
            let pos = Float(ta / (ta + 1)), neg: Float = 0.5, d = Float(pow(t / (t + 1), 2))
            for p in 0..<2 { _ = cfr(root, p, sides[p].weight, sides[1 - p].weight, pos, neg, d) }
        }
    }

    private func cfr(_ n: Int, _ p: Int, _ selfReach: [Float], _ oppReach: [Float], _ pos: Float, _ neg: Float, _ d: Float) -> [Float] {
        let node = nodes[n]
        switch node.kind {
        case .fold, .showdown:
            return terminalValues(node, player: p, oppReach: oppReach)
        case .chance:
            let wgt = chanceWeight(node)
            var value = [Float](repeating: 0, count: sides[p].count)
            for (k, child) in node.children.enumerated() {
                var s = selfReach, o = oppReach
                mask(&s, side: p, card: node.dealt[k]); mask(&o, side: 1 - p, card: node.dealt[k])
                var v = cfr(child, p, s, o, pos, neg, d)
                mask(&v, side: p, card: node.dealt[k])
                for h in 0..<v.count { value[h] += wgt * v[h] }
            }
            return value
        case .decision(let actor):
            let k = node.actions.count
            let sigma = currentStrategy(node, player: actor)
            let na = sides[actor].count
            if actor != p {
                var value = [Float](repeating: 0, count: sides[p].count)
                for a in 0..<k {
                    var reach = oppReach
                    for h in 0..<na { reach[h] *= sigma[a * na + h] }
                    let v = cfr(node.children[a], p, selfReach, reach, pos, neg, d)
                    for h in 0..<value.count { value[h] += v[h] }
                }
                return value
            }
            var actionValues: [[Float]] = []
            var value = [Float](repeating: 0, count: na)
            for a in 0..<k {
                var reach = selfReach
                for h in 0..<na { reach[h] *= sigma[a * na + h] }
                let v = cfr(node.children[a], p, reach, oppReach, pos, neg, d)
                actionValues.append(v)
                for h in 0..<na { value[h] += sigma[a * na + h] * v[h] }
            }
            for a in 0..<k {
                for h in 0..<na {
                    let i = node.offset + a * na + h
                    let r = regrets[i]
                    regrets[i] = r * (r > 0 ? pos : neg) + actionValues[a][h] - value[h]
                    strategySum[i] = (strategySum[i] + selfReach[h] * sigma[a * na + h]) * d
                }
            }
            return value
        }
    }

    // MARK: Evaluation

    private func evaluate(_ n: Int, _ p: Int, _ oppReach: [Float], bestResponse: Bool) -> [Float] {
        let node = nodes[n]
        switch node.kind {
        case .fold, .showdown:
            return terminalValues(node, player: p, oppReach: oppReach)
        case .chance:
            let wgt = chanceWeight(node)
            var value = [Float](repeating: 0, count: sides[p].count)
            for (k, child) in node.children.enumerated() {
                var o = oppReach
                mask(&o, side: 1 - p, card: node.dealt[k])
                var v = evaluate(child, p, o, bestResponse: bestResponse)
                mask(&v, side: p, card: node.dealt[k])
                for h in 0..<v.count { value[h] += wgt * v[h] }
            }
            return value
        case .decision(let actor):
            let sigma = averageStrategy(node, player: actor)
            let na = sides[actor].count, k = node.actions.count
            if actor != p {
                var value = [Float](repeating: 0, count: sides[p].count)
                for a in 0..<k {
                    var reach = oppReach
                    for h in 0..<na { reach[h] *= sigma[a * na + h] }
                    let v = evaluate(node.children[a], p, reach, bestResponse: bestResponse)
                    for h in 0..<value.count { value[h] += v[h] }
                }
                return value
            }
            var value = [Float](repeating: bestResponse ? -.greatestFiniteMagnitude : 0, count: na)
            for a in 0..<k {
                let v = evaluate(node.children[a], p, oppReach, bestResponse: bestResponse)
                for h in 0..<na { value[h] = bestResponse ? max(value[h], v[h]) : value[h] + sigma[a * na + h] * v[h] }
            }
            return value
        }
    }

    private func total(_ values: [Float], player p: Int) -> Double {
        var sum = 0.0
        for i in 0..<sides[p].count { sum += Double(values[i]) * Double(sides[p].weight[i]) }
        return sum / pairMass
    }

    /// Expected values (pot-share convention, chips) under the average strategies.
    public func expectedValues() -> (oop: Double, ip: Double) {
        (total(evaluate(root, 0, sides[1].weight, bestResponse: false), player: 0),
         total(evaluate(root, 1, sides[0].weight, bestResponse: false), player: 1))
    }

    /// Exploitability of the average strategies as a percentage of the starting pot.
    public func exploitability() -> Double {
        let br0 = total(evaluate(root, 0, sides[1].weight, bestResponse: true), player: 0)
        let br1 = total(evaluate(root, 1, sides[0].weight, bestResponse: true), player: 1)
        return max(0, (br0 + br1) / 2) / spot.pot * 100
    }

    @discardableResult
    public func solve(targetExploitability target: Double, maxIterations: Int, checkEvery: Int = 10) -> RiverSolver.SolveResult {
        let clock = ContinuousClock()
        var time = Duration.zero
        var curve: [(iteration: Int, exploitability: Double)] = []
        var e = Double.infinity
        while iteration < maxIterations {
            let t0 = clock.now
            iterate(min(checkEvery, maxIterations - iteration))
            time += clock.now - t0
            e = exploitability()
            curve.append((iteration, e))
            if e <= target { break }
        }
        let s = Double(time.components.seconds) + Double(time.components.attoseconds) * 1e-18
        return RiverSolver.SolveResult(iterations: iteration, exploitability: e, solveSeconds: s, curve: curve)
    }

    /// Root strategy (first action, OOP) for one hand.
    public func rootFrequencies(hand: HoleCards) -> [Double]? {
        guard case .decision(let actor) = nodes[root].kind else { return nil }
        let i = sides[actor].comboIndex[Int(hand.high.rawValue) * 52 + Int(hand.low.rawValue)]
        guard i >= 0 else { return nil }
        let s = averageStrategy(nodes[root], player: actor), n = sides[actor].count
        return nodes[root].actions.indices.map { Double(s[$0 * n + i]) }
    }
}
