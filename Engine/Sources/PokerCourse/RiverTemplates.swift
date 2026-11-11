import PokerCore
import PokerSolver

/// Units 7-9: questions answered by solving the river on the device.
///
/// Every spot is big blind (out of position) vs button (in position) on a random river, pot
/// 10 bb with 50 bb behind, bets of 33% and 75% pot plus all-in. Solves stop at 0.5% pot
/// exploitability (or 400 DCFR iterations), well inside the 1% equal-EV grading tolerance.
enum RiverStudy {
    static let bigBlind = try! HandRange("22+, A2s+, K2s+, Q4s+, J6s+, T6s+, 96s+, 85s+, 74s+, 63s+, 53s+, 43s, A2o+, K7o+, Q8o+, J8o+, T8o+, 98o")
    static let button = try! HandRange("22+, A2s+, K5s+, Q8s+, J8s+, T8s+, 97s+, 86s+, 75s+, 65s, 54s, A7o+, K9o+, QTo+, JTo")
    static let pot = 10.0, stack = 50.0
    static let config = RiverTreeConfig(betSizes: [0.33, 0.75], raiseSizes: [], allowAllIn: true, maxBets: 2)
    static let target = 0.5, maxIterations = 400
}

extension Gen {
    mutating func riverBoard() -> [Card] { cards(5) }

    func solvedRiver(_ board: [Card]) throws -> RiverSolver {
        let solver = try RiverSolver(spot: RiverSpot(board: board, pot: RiverStudy.pot, stack: RiverStudy.stack,
                                                     oop: RiverStudy.bigBlind, ip: RiverStudy.button, config: RiverStudy.config))
        solver.solve(targetExploitability: RiverStudy.target, maxIterations: RiverStudy.maxIterations, checkEvery: 25)
        return solver
    }

    mutating func pickHand(_ solver: RiverSolver, player: Int, where ok: (HoleCards) -> Bool = { _ in true }) -> HoleCards {
        let hands = solver.hands(player: player)
        for _ in 0..<200 { let h = pick(hands); if ok(h) { return h } }
        return pick(hands)
    }

    static func evList(_ labels: [String], _ evs: [Double]) -> String {
        labels.indices.map { "\(labels[$0]) \(Fmt.bb(evs[$0]))" }.joined(separator: ", ")
    }

    // MARK: Unit 7

    mutating func rangeAdvantage() throws -> Question {
        let board = riverBoard()
        let solver = try RiverSolver(spot: RiverSpot(board: board, pot: RiverStudy.pot, stack: RiverStudy.stack,
                                                     oop: RiverStudy.bigBlind, ip: RiverStudy.button, config: RiverStudy.config))
        let eq = solver.rangeEquity()
        let d = (eq.ip - eq.oop) * 100
        return Question(id: id, concept: .rangeAdvantage, kind: .estimate,
                        prompt: "On this river, whose range has more equity?",
                        board: board, facts: [.init("Big blind", "defends ~42%, out of position"), .init("Button", "opens ~41%, in position")],
                        options: [.init("Big blind", ev: -d), .init("About even", ev: 0), .init("Button", ev: d)], pot: 100,
                        explanation: "Range vs range on this board: button \(Fmt.pct(eq.ip)), big blind \(Fmt.pct(eq.oop)) (every hand pair enumerated). Answers within 1 point of the best count as correct. The button's tighter opening range keeps more strong hands; low, connected boards help the big blind.")
    }

    mutating func riverBet() throws -> Question {
        let board = riverBoard()
        let solver = try solvedRiver(board)
        let node = solver.node(path: [0])                       // big blind checked
        let hero = pickHand(solver, player: 1)
        let evs = solver.actionEVs(at: node, path: [0], hand: hero)!
        let freqs = solver.frequencies(at: node, hand: hero)!
        let labels = solver.nodes[node].actions.map(\.label)
        return Question(id: id, concept: .riverPlay, kind: .decision,
                        prompt: "The big blind checks the river to you. What do you do?",
                        hero: [hero.high, hero.low], board: board,
                        facts: [.init("Pot", Fmt.bb(RiverStudy.pot)), .init("Behind", Fmt.bb(RiverStudy.stack)), .init("Villain", "big blind defence range")],
                        options: labels.indices.map { .init(labels[$0], ev: evs[$0]) }, pot: RiverStudy.pot,
                        explanation: "Solved on this device (DCFR): EVs \(Self.evList(labels, evs)), counting what you win from the pot minus your river bets. The equilibrium plays this hand \(Self.freqText(labels, freqs)). Thin value bets want worse hands to call; bluffs want better hands to fold.")
    }

    static func freqText(_ labels: [String], _ f: [Double]) -> String {
        let used = f.indices.filter { f[$0] >= 0.05 }.sorted { f[$0] > f[$1] }
        return used.map { "\(labels[$0].lowercased()) \(Fmt.pct(f[$0], 0))" }.joined(separator: ", ")
    }

    // MARK: Units 8 and 9

    /// Big blind checks, the button bets 75%: fold, call or raise? With `exploit`, the button
    /// is a nit that bets only the top quarter of its range (and never bluffs).
    mutating func riverDefend(exploit: Bool) throws -> Question {
        let board = riverBoard()
        let solver = try solvedRiver(board)
        let afterCheck = solver.node(path: [0])
        let betIndex = solver.nodes[afterCheck].actions.firstIndex { $0.label == "Bet 75%" } ?? 1
        let facing = solver.node(path: [0, betIndex])
        let path = [0, betIndex]
        var overrides: RiverSolver.Overrides = [:]
        if exploit {
            overrides[afterCheck] = solver.override(at: afterCheck) { h in
                let strong = (solver.strengthPercentile(h, player: 1) ?? 0) >= 0.75
                return solver.nodes[afterCheck].actions.indices.map { a in strong ? (a == betIndex ? 1 : 0) : (a == 0 ? 1 : 0) }
            }
        }
        // A hand that checks at least some of the time and isn't trivially strong or weak.
        let hero = pickHand(solver, player: 0) { h in
            let check = solver.frequencies(at: solver.root, hand: h)?[0] ?? 0
            let pct = solver.strengthPercentile(h, player: 0) ?? 0
            return check > 0.3 && (exploit ? pct > 0.45 && pct < 0.85 : pct > 0.2)
        }
        let labels = solver.nodes[facing].actions.map(\.label)
        let evs = solver.actionEVs(at: facing, path: path, hand: hero, overrides: overrides)!
        let bet = RiverStudy.pot * 0.75
        var explanation = "EVs relative to folding, \(exploit ? "against this player" : "at equilibrium"): \(Self.evList(labels, evs))."
        if exploit {
            let gto = solver.actionEVs(at: facing, path: path, hand: hero)!
            explanation += " Against a balanced button they'd be \(Self.evList(labels, gto)). A player who only bets the top of their range has no bluffs, so bluff-catchers lose value: fold more than MDF says."
        } else {
            let f = solver.frequencies(at: facing, hand: hero)!
            explanation += " The equilibrium plays this hand \(Self.freqText(labels, f)). Blockers matter: holding cards that the button would value bet makes calling better."
        }
        return Question(id: id, concept: exploit ? .exploits : .riverPlay, kind: .decision,
                        prompt: exploit ? "You check, and a very tight player bets \(Fmt.bb(bet)) into \(Fmt.bb(RiverStudy.pot)). They only bet their strongest hands. Your move?"
                                        : "You check, and the button bets \(Fmt.bb(bet)) into \(Fmt.bb(RiverStudy.pot)). Your move?",
                        hero: [hero.high, hero.low], board: board,
                        facts: [.init("Pot", Fmt.bb(RiverStudy.pot)), .init("Bet", Fmt.bb(bet)), .init("Villain", exploit ? "bets top 25% only" : "button opening range")],
                        options: labels.indices.map { .init(labels[$0], ev: evs[$0]) }, pot: RiverStudy.pot + bet,
                        explanation: explanation)
    }

    /// You lead into a calling station that never folds to a bet.
    mutating func exploitStation() throws -> Question {
        let board = riverBoard()
        let solver = try solvedRiver(board)
        let root = solver.nodes[solver.root]
        var overrides: RiverSolver.Overrides = [:]
        for (a, action) in root.actions.enumerated() where action.kind != .check {
            let facing = root.children[a]
            overrides[facing] = solver.override(at: facing) { _ in
                solver.nodes[facing].actions.map { $0.kind == .call ? 1.0 : 0.0 }
            }
        }
        let hero = pickHand(solver, player: 0) { h in
            let pct = solver.strengthPercentile(h, player: 0) ?? 0
            return pct > 0.75 || pct < 0.2
        }
        let labels = root.actions.map(\.label)
        let evs = solver.actionEVs(at: solver.root, path: [], hand: hero, overrides: overrides)!
        let gto = solver.actionEVs(at: solver.root, path: [], hand: hero)!
        return Question(id: id, concept: .exploits, kind: .decision,
                        prompt: "First to act on the river against a calling station: they call every bet and never raise. What do you do?",
                        hero: [hero.high, hero.low], board: board,
                        facts: [.init("Pot", Fmt.bb(RiverStudy.pot)), .init("Behind", Fmt.bb(RiverStudy.stack)), .init("Villain", "calls any bet")],
                        options: labels.indices.map { .init(labels[$0], ev: evs[$0]) }, pot: RiverStudy.pot,
                        explanation: "EVs against the station: \(Self.evList(labels, evs)). Against a balanced button: \(Self.evList(labels, gto)). Versus a player who never folds, bet strong hands as big as they'll pay, and stop bluffing.")
    }
}
