import PokerCore
import PokerSolver

public enum CourseError: Error, Equatable, Sendable {
    /// The template needs the river solver, which this build doesn't have yet.
    case requiresRiverSolver
}

/// A question template. Each review deals a fresh spot from it (the adaptive layer schedules
/// templates, not individual hands).
public enum TemplateID: String, CaseIterable, Hashable, Sendable, Codable {
    case requiredEquity, callOrFold
    case equityVsHand, equityVsRange
    case openingWidth, openOrFold
    case kuhn
    case mdf, bluffRatio, bluffCatch
    case pushFold, callShove
    case rangeAdvantage, riverBet, riverDefend
    case exploitNit, exploitStation
    case icmCall, caveats

    public var concept: Concept {
        switch self {
        case .requiredEquity: .requiredEquity
        case .callOrFold: .callOrFold
        case .equityVsHand: .equityVsHand
        case .equityVsRange: .equityVsRange
        case .openingWidth, .openOrFold: .openingRanges
        case .kuhn, .caveats: .gtoBasics
        case .mdf: .mdf
        case .bluffRatio: .bluffRatio
        case .bluffCatch: .bluffCatching
        case .pushFold: .pushFold
        case .callShove: .callShove
        case .rangeAdvantage: .rangeAdvantage
        case .riverBet, .riverDefend: .riverPlay
        case .exploitNit, .exploitStation: .exploits
        case .icmCall: .icm
        }
    }

    public var needsRiverSolver: Bool {
        [.rangeAdvantage, .riverBet, .riverDefend, .exploitNit, .exploitStation].contains(self)
    }

    public func generate(seed: UInt64) async throws -> Question {
        var g = Gen(seed: seed, template: self)
        switch self {
        case .requiredEquity: return g.requiredEquity()
        case .callOrFold: return try await g.callOrFold()
        case .equityVsHand: return try await g.equityVsHand()
        case .equityVsRange: return try await g.equityVsRange()
        case .openingWidth: return g.openingWidth()
        case .openOrFold: return g.openOrFold()
        case .kuhn: return g.kuhn()
        case .mdf: return g.mdf()
        case .bluffRatio: return g.bluffRatio()
        case .bluffCatch: return g.bluffCatch()
        case .pushFold: return await g.pushFold()
        case .callShove: return await g.callShove()
        case .icmCall: return g.icmCall()
        case .caveats: return g.caveats()
        case .rangeAdvantage, .riverBet, .riverDefend, .exploitNit, .exploitStation:
            guard let river = RiverQuestions.generator else { throw CourseError.requiresRiverSolver }
            return try await river(self, seed)
        }
    }
}

/// Hook for the river-solver templates (units 7-9), installed by the river module.
public enum RiverQuestions {
    nonisolated(unsafe) public static var generator: (@Sendable (TemplateID, UInt64) async throws -> Question)?
}

/// Named villain ranges used by the generators (study ranges, not solver output).
enum StudyRange {
    static let all: [(name: String, notation: String)] = [
        ("Tight open", "77+, ATs+, KJs+, QJs, AJo+, KQo"),
        ("Wide open", "22+, A2s+, K8s+, Q9s+, J9s+, T8s+, 98s, 87s, 76s, A8o+, KTo+, QTo+, JTo"),
        ("3-bet", "TT+, AQs+, AKo, A5s-A4s"),
        ("Big pairs", "QQ+"),
        ("Any two cards", "random"),
    ]
}

/// Bet sizes as fractions of the pot.
let betFractions: [Double] = [0.25, 1.0 / 3, 0.5, 2.0 / 3, 0.75, 1, 1.5, 2]

func sizeName(_ s: Double) -> String {
    switch s {
    case 0.25: "a quarter pot"
    case 1.0 / 3: "a third of the pot"
    case 0.5: "half pot"
    case 2.0 / 3: "two-thirds pot"
    case 0.75: "three-quarters pot"
    case 1: "pot"
    case 1.5: "1.5x pot"
    case 2: "2x pot"
    default: "\(Fmt.pct(s, 0)) of the pot"
    }
}

/// Generator state for one question.
struct Gen {
    var rng: Xoshiro256
    var used = CardSet()
    let template: TemplateID
    let id: String

    init(seed: UInt64, template: TemplateID) {
        rng = Xoshiro256(seed: seed)
        self.template = template
        id = "\(template.rawValue)-\(seed)"
    }

    // MARK: Dealing

    mutating func int(_ range: ClosedRange<Int>) -> Int { range.lowerBound + Int(rng.next(below: UInt64(range.count))) }
    mutating func pick<T>(_ xs: [T]) -> T { xs[Int(rng.next(below: UInt64(xs.count)))] }
    mutating func chance(_ p: Double) -> Bool { rng.nextUnit() < p }

    mutating func card() -> Card {
        while true {
            let c = Card(rawValue: UInt8(rng.next(below: 52)))
            if !used.contains(c) { used.insert(c); return c }
        }
    }
    mutating func hand() -> HoleCards { HoleCards(card(), card()) }
    mutating func cards(_ n: Int) -> [Card] { (0..<n).map { _ in card() }.sorted(by: >) }

    // MARK: Option builders

    /// Four estimate options (whole percentages, at least `gap` points apart): the rounded
    /// truth, the given distractors where they're far enough away, then evenly spaced fillers.
    mutating func estimateOptions(truth: Double, distractors: [Double] = [], gap: Double = 0.04) -> [Question.Option] {
        let right = (truth * 100).rounded() / 100
        var values = [right]
        func fits(_ v: Double) -> Bool { v >= 0.01 && v <= 0.99 && values.allSatisfy { abs($0 - v) >= gap - 1e-9 } }
        for d in distractors.shuffled(using: &rng) {
            let v = (d * 100).rounded() / 100
            if values.count < 4, fits(v) { values.append(v) }
        }
        var step = 1
        while values.count < 4 {
            for v in [right + Double(step) * 0.08, right - Double(step) * 0.08] where values.count < 4 && fits(v) {
                values.append(v)
            }
            step += 1
        }
        return values.sorted().map { .init(Fmt.pct($0, 0), ev: -abs($0 - truth) * 100) }
    }

    func estimate(_ prompt: String, options: [Question.Option], explanation: String, facts: [Question.Fact] = [],
                  hero: [Card] = [], villain: [Card] = [], board: [Card] = []) -> Question {
        Question(id: id, concept: template.concept, kind: .estimate, prompt: prompt, hero: hero, villain: villain,
                 board: board, facts: facts, options: options, pot: 100, explanation: explanation)
    }

    /// A question with one right answer and no EV: wrong answers grade as a 10-point mistake.
    func fact(_ prompt: String, answers: [String], correct: Int, explanation: String) -> Question {
        Question(id: id, concept: template.concept, kind: .estimate, prompt: prompt,
                 options: answers.indices.map { .init(answers[$0], ev: $0 == correct ? 0 : -10) },
                 pot: 100, explanation: explanation)
    }

    // MARK: Unit 1: EV and pot odds

    mutating func requiredEquity() -> Question {
        let s = pick(betFractions)
        let pot = Double(int(2...20) * 2)
        let bet = pot * s
        let truth = s / (2 * s + 1)
        return estimate("Villain bets \(sizeName(s)). How much equity do you need to call?",
                        options: estimateOptions(truth: truth, distractors: [s, s / (1 + s), 1 / (1 + s)]),
                        explanation: "You call \(Fmt.bb(bet)) to win a final pot of \(Fmt.bb(pot + 2 * bet)). Required equity = call ÷ final pot = \(Fmt.pct(truth)). As a formula: s / (2s + 1) with s = \(Fmt.num(s, 2)).",
                        facts: [.init("Pot", Fmt.bb(pot)), .init("Bet", Fmt.bb(bet))])
    }

    mutating func callOrFold() async throws -> Question {
        let hero = hand()
        let villain = pick(Array(StudyRange.all.dropLast()))
        let board = cards(chance(0.5) ? 3 : 4)
        let request = EquityRequest(players: [HandRange(hero), try HandRange(villain.notation)], board: CardSet(board))
        let equity = try await equityOf(request, seed: rng.next())
        let pot = Double(int(3...30) * 2)
        let s = pick(betFractions)
        let bet = (pot * s * 2).rounded() / 2
        let callEV = equity * (pot + 2 * bet) - bet
        let need = bet / (pot + 2 * bet)
        return Question(id: id, concept: .callOrFold, kind: .decision,
                        prompt: "Villain bets \(Fmt.bb(bet)) into \(Fmt.bb(pot)) and will check down after a call. Call or fold?",
                        hero: [hero.high, hero.low], board: board,
                        facts: [.init("Villain", villain.name), .init("Pot", Fmt.bb(pot)), .init("Bet", Fmt.bb(bet))],
                        options: [.init("Fold", ev: 0), .init("Call", ev: callEV)], pot: pot + bet,
                        explanation: "Your equity is \(Fmt.pct(equity)) and a call needs \(Fmt.pct(need)). Calling is worth \(Fmt.signed(callEV)) compared with folding (equity × \(Fmt.bb(pot + 2 * bet)) − \(Fmt.bb(bet))).")
    }

    // MARK: Unit 2: equity

    mutating func equityVsHand() async throws -> Question {
        let hero = hand(), villain = hand()
        let board = chance(0.5) ? [] : cards(3)
        let e = try await equityOf(EquityRequest(hands: [hero, villain], board: CardSet(board)), seed: rng.next())
        return estimate("How often does your hand win against theirs?", options: spreadOptions(truth: e),
                        explanation: "Exact equity: \(Fmt.pct(e)) (every remaining board enumerated; ties count half).",
                        hero: [hero.high, hero.low], villain: [villain.high, villain.low], board: board)
    }

    mutating func equityVsRange() async throws -> Question {
        let hero = hand()
        let villain = pick(Array(StudyRange.all.dropLast()))
        let board = chance(0.4) ? [] : cards(3)
        let e = try await equityOf(EquityRequest(players: [HandRange(hero), try HandRange(villain.notation)], board: CardSet(board)), seed: rng.next())
        return estimate("How often does your hand win against this range?", options: spreadOptions(truth: e),
                        explanation: "Against \(villain.name.lowercased()) (\(villain.notation)) your equity is \(Fmt.pct(e)). Ranges hit boards differently from single hands, so think about the whole range.",
                        facts: [.init("Villain", villain.name)], hero: [hero.high, hero.low], board: board)
    }

    /// Four options 13 points apart, one within 6.5 points of the truth (like the prototype).
    mutating func spreadOptions(truth: Double) -> [Question.Option] {
        let slot = int(0...3)
        let start = min(max((truth * 100).rounded() - Double(slot) * 13, 2), 98 - 39)
        return (0..<4).map { let v = (start + Double($0) * 13) / 100; return .init(Fmt.pct(v, 0), ev: -abs(v - truth) * 100) }
    }

    // MARK: Unit 3: preflop

    /// 6-max, 100 bb opening (RFI) widths from the research doc (Upswing).
    static let openWidths: [(seat: String, width: Double)] = [("UTG", 0.16), ("CO", 0.249), ("BTN", 0.409), ("SB", 0.478)]

    mutating func openingWidth() -> Question {
        let (seat, width) = pick(Self.openWidths)
        if chance(0.5) {
            return estimate("Six-max, 100 bb deep, folded to you in the \(seat). About what share of hands do you open?",
                            options: Self.openWidths.map { .init(Fmt.pct($0.width, 0), ev: -abs($0.width - width) * 100) },
                            explanation: "Typical 100 bb opening ranges: UTG 16%, CO 25%, BTN 41%, SB 48%. Fewer players left to act means fewer hands that can wake up with something, so later seats open wider.")
        }
        var other = pick(Self.openWidths)
        while other.seat == seat { other = pick(Self.openWidths) }
        let pair = [(seat, width), other].shuffled(using: &rng)
        let wider = pair[0].1 > pair[1].1 ? 0 : 1
        return fact("Which seat should open more hands?", answers: pair.map(\.0), correct: wider,
                    explanation: "\(pair[wider].0) opens about \(Fmt.pct(pair[wider].1, 0)) versus \(Fmt.pct(pair[1 - wider].1, 0)) for \(pair[1 - wider].0). The closer you are to the button, the fewer players can have a strong hand behind you.")
    }

    /// Hand classes ordered by preflop equity against a random hand, with cumulative combo share.
    static let strengthOrder: [(hc: HandClass, cumulative: Double)] = {
        let t = PreflopEquityTable.shared
        func vsRandom(_ i: Int) -> Double {
            var num = 0.0, den = 0.0
            for j in 0..<169 { let w = Double(t.pairCount[i * 169 + j]); num += w * Double(t.equity[i * 169 + j]); den += w }
            return num / den
        }
        let sorted = HandClass.all.sorted { vsRandom($0.index) > vsRandom($1.index) }
        var acc = 0.0
        return sorted.map { acc += Double($0.comboCount) / 1326; return ($0, acc) }
    }()

    mutating func openOrFold() -> Question {
        let (seat, width) = pick(Self.openWidths)
        // Only hands clearly inside or clearly outside the range: no boundary hands.
        let clear = Self.strengthOrder.filter { $0.cumulative <= width * 0.6 || ($0.cumulative >= width * 1.6 && $0.cumulative <= 0.95) }
        let (hc, cumulative) = pick(clear)
        let open = cumulative <= width
        let combo = hc.combos[int(0...(hc.comboCount - 1))]
        let answers = ["Raise", "Limp", "Fold"]
        let correct = open ? 0 : 2
        let q = Question(id: id, concept: .openingRanges, kind: .estimate,
                         prompt: "Six-max, 100 bb, folded to you in the \(seat). What do you do?",
                         hero: [combo.high, combo.low], facts: [.init("Opening range", "about \(Fmt.pct(width, 0)) of hands")],
                         options: answers.indices.map { .init(answers[$0], ev: $0 == correct ? 0 : ($0 == 1 ? -5 : -10)) },
                         pot: 100,
                         explanation: "\(hc.spokenName) is in the top \(Fmt.pct(cumulative, 0)) of hands by equity against a random hand, so it's clearly \(open ? "inside" : "outside") a \(Fmt.pct(width, 0)) \(seat) range. \(open ? "Open with a raise: limping lets the blinds see a cheap flop and gives up the pot you could win right away." : "Fold: playing it loses more than the blinds you'd win.") (Ranking by equity vs a random hand is a simplification of real charts, so only clear-cut hands appear here.)")
        return q
    }

    // MARK: Unit 4: Kuhn poker (closed form)

    mutating func kuhn() -> Question {
        switch int(0...3) {
        case 0:
            let answers = ["−1/18 chip", "0", "+1/18 chip", "−1/6 chip"]
            let order = Array(answers.indices).shuffled(using: &rng)
            return fact("In Kuhn poker (3 cards, 1-chip antes), what is the first player's value per hand when both play the equilibrium?",
                        answers: order.map { answers[$0] }, correct: order.firstIndex(of: 0)!,
                        explanation: "The game value for player 1 is −1/18 ≈ −0.056 chips per hand: acting first is a small disadvantage. CFR converges to exactly this value (see the Kuhn lab).")
        case 1:
            let alpha = pick([0.0, 0.1, 0.2, 1.0 / 3])
            return estimate("Kuhn poker equilibrium: player 1 bets the Jack (a bluff) \(Fmt.pct(alpha, 0)) of the time. How often must they bet the King?",
                            options: estimateOptions(truth: 3 * alpha, distractors: [alpha, 2 * alpha, 1 - alpha, 0.5]),
                            explanation: "Player 1's equilibria form a family: bluff the Jack with α ∈ [0, 1/3] and bet the King 3α of the time, so value bets and bluffs stay balanced. Here 3 × \(Fmt.pct(alpha, 0)) = \(Fmt.pct(3 * alpha, 0)).")
        case 2:
            return estimate("Kuhn poker: player 2 holds the Queen and faces a bet. At equilibrium, how often do they call?",
                            options: estimateOptions(truth: 1.0 / 3, distractors: [0.5, 0, 2.0 / 3, 1]),
                            explanation: "Player 2 calls with the Queen 1/3 of the time. That makes player 1 indifferent to bluffing the Jack: the bluff wins 2 chips when Q folds and loses 1 when it calls.")
        default:
            return fact("Your opponent plays a perfect equilibrium strategy heads-up. What is the most you can expect to win in the long run?",
                        answers: ["Nothing beyond the game value", "More, if you play GTO too", "More, by mixing randomly", "Whatever your card luck gives"],
                        correct: 0,
                        explanation: "An equilibrium is unexploitable: the best any opponent can do against it is the game value (break-even in a symmetric game). GTO profits only when opponents deviate.")
        }
    }

    // MARK: Unit 5: toy games

    mutating func mdf() -> Question {
        let s = pick(betFractions)
        let truth = 1 / (1 + s)
        return estimate("Villain bets \(sizeName(s)). What is your minimum defence frequency?",
                        options: estimateOptions(truth: truth, distractors: [s / (1 + s), s / (2 * s + 1), 1 - s / (2 * s + 1)]),
                        explanation: "MDF = 1 / (1 + s) = \(Fmt.pct(truth)). Defending less lets a pure bluff profit. Note MDF only makes 0%-equity bluffs break even; out of position solvers often defend a bit less.")
    }

    mutating func bluffRatio() -> Question {
        let s = pick(betFractions)
        if chance(0.5) {
            let truth = s / (2 * s + 1)
            return estimate("You bet \(sizeName(s)) on the river with a polarised range. What share of your bets should be bluffs?",
                            options: estimateOptions(truth: truth, distractors: [s / (1 + s), 1 / (1 + s), 0.5]),
                            explanation: "Bluff share = s / (2s + 1) = \(Fmt.pct(truth)): exactly the pot odds you give the caller, which makes their bluff-catchers indifferent.")
        }
        let truth = s / (1 + s)
        return estimate("You bluff \(sizeName(s)). How often must villain fold for the bluff to break even?",
                        options: estimateOptions(truth: truth, distractors: [s / (2 * s + 1), 1 / (1 + s), 0.5]),
                        explanation: "Alpha = s / (1 + s) = \(Fmt.pct(truth)): you risk s to win 1 pot.")
    }

    mutating func bluffCatch() -> Question {
        let s = pick([0.5, 2.0 / 3, 0.75, 1])
        let pot = Double(int(5...25) * 2)
        let bet = (pot * s * 2).rounded() / 2
        let indifferent = bet / (pot + 2 * bet)
        let bluffShare = min(0.6, max(0.05, indifferent + pick([-0.15, -0.1, -0.06, 0.06, 0.1, 0.15])))
        let callEV = bluffShare * (pot + bet) - (1 - bluffShare) * bet
        return Question(id: id, concept: .bluffCatching, kind: .decision,
                        prompt: "River. You hold a pure bluff-catcher: it beats every bluff and loses to every value bet. Villain bets \(Fmt.bb(bet)) into \(Fmt.bb(pot)), bluffing \(Fmt.pct(bluffShare, 0)) of the time. Call or fold?",
                        facts: [.init("Pot", Fmt.bb(pot)), .init("Bet", Fmt.bb(bet)), .init("Villain's bluffs", Fmt.pct(bluffShare, 0))],
                        options: [.init("Fold", ev: 0), .init("Call", ev: callEV)], pot: pot + bet,
                        explanation: "Calling wins \(Fmt.bb(pot + bet)) against bluffs and loses \(Fmt.bb(bet)) against value: EV = \(Fmt.pct(bluffShare, 0)) × \(Fmt.bb(pot + bet)) − \(Fmt.pct(1 - bluffShare, 0)) × \(Fmt.bb(bet)) = \(Fmt.signed(callEV)). You're indifferent at \(Fmt.pct(indifferent)) bluffs, the balanced bluff share for this size.")
    }

    // MARK: Unit 6: push/fold (CFR+ solved)

    mutating func pushFold() async -> Question {
        let stack = Double(int(3...15))
        let sol = await PushFoldCache.shared.solution(stack: stack)
        let h = hand()
        let hc = h.handClass
        let m = PushFoldMatrices.shared
        let s = PushFoldMatrices.stride, i = hc.index
        var ac = 0.0, wc = 0.0
        for j in 0..<169 { ac += Double(m.a[i * s + j]) * sol.call[j]; wc += Double(m.w[i * s + j]) * sol.call[j] }
        let r = Double(m.rowSum[i])
        let push = (stack * ac + r - wc) / r
        let fold = -0.5
        return Question(id: id, concept: .pushFold, kind: .decision,
                        prompt: "Heads-up, \(Int(stack)) bb effective, you're in the small blind. Shove or fold?",
                        hero: [h.high, h.low], facts: [.init("Stack", "\(Int(stack)) bb"), .init("Blinds", "0.5 / 1 bb, no ante")],
                        options: [.init("Fold", ev: fold), .init("Shove", ev: push)], pot: 1.5,
                        explanation: "Against the Nash calling range (\(Fmt.pct(sol.callFraction, 0)) of hands), shoving \(hc) is worth \(Fmt.signed(push)) per hand and folding \(Fmt.signed(fold)). The Nash strategy shoves \(hc) \(Fmt.pct(sol.push[i], 0)) of the time (CFR+, \(sol.iterations) iterations, solved on this device).")
    }

    mutating func callShove() async -> Question {
        let stack = Double(int(3...15))
        let sol = await PushFoldCache.shared.solution(stack: stack)
        let m = PushFoldMatrices.shared
        let s = PushFoldMatrices.stride
        var h = hand()
        var wp = 0.0, ap = 0.0
        // Deal a hand that the shoving range can actually face (non-zero weight).
        for _ in 0..<50 {
            let j = h.handClass.index
            wp = 0; ap = 0
            for i in 0..<169 { ap += Double(m.a[j * s + i]) * sol.push[i]; wp += Double(m.w[j * s + i]) * sol.push[i] }
            if wp > 1e-9 { break }
            used = CardSet(); h = hand()
        }
        let hc = h.handClass, j = hc.index
        let call = stack * ap / wp
        let fold = -1.0
        return Question(id: id, concept: .callShove, kind: .decision,
                        prompt: "Heads-up, \(Int(stack)) bb effective. The small blind shoves; you're in the big blind. Call or fold?",
                        hero: [h.high, h.low], facts: [.init("Stack", "\(Int(stack)) bb"), .init("Villain shoves", Fmt.pct(sol.pushFraction, 0) + " of hands")],
                        options: [.init("Fold", ev: fold), .init("Call", ev: call)], pot: stack + 1,
                        explanation: "Against the Nash shoving range, calling with \(hc) is worth \(Fmt.signed(call)) and folding gives up your big blind (\(Fmt.signed(fold))). Nash calls with \(hc) \(Fmt.pct(sol.call[j], 0)) of the time.")
    }

    // MARK: Unit 10: ICM

    mutating func icmCall() -> Question {
        let payouts = [50.0, 30, 20]
        var stacks: [Double] = []
        repeat {
            stacks = [Double(int(4...20) * 1000), Double(int(4...20) * 1000), Double(int(2...12) * 1000)]
        } while stacks[1] < stacks[0] / 2
        // Hero (0) faces an all-in from the chip-leading villain (1); player 2 has folded.
        let risk = min(stacks[0], stacks[1])
        let equity = Double(int(35...65)) / 100
        var win = stacks, lose = stacks
        win[0] += risk; win[1] -= risk
        lose[0] -= risk; lose[1] += risk
        let fold = ICM.equities(stacks: stacks, payouts: payouts)[0]
        let eqWin = ICM.equities(stacks: win, payouts: payouts)[0]
        let eqLose = ICM.equities(stacks: lose, payouts: payouts)[0]
        let call = equity * eqWin + (1 - equity) * eqLose
        let icmNeed = (fold - eqLose) / (eqWin - eqLose)
        return Question(id: id, concept: .icm, kind: .decision,
                        prompt: "Three left, prizes 50 / 30 / 20. Villain shoves and you'd risk \(Int(risk)) chips with \(Fmt.pct(equity, 0)) equity. Call or fold?",
                        facts: [.init("Your stack", "\(Int(stacks[0]))"), .init("Villain", "\(Int(stacks[1]))"), .init("Third player", "\(Int(stacks[2]))"), .init("Your equity", Fmt.pct(equity, 0))],
                        options: [.init("Fold", ev: fold), .init("Call", ev: call)], pot: 100,
                        explanation: "In chips this is a coin-flip-style call needing 50%, but prizes aren't chips. ICM values folding at \(Fmt.num(fold))% of the prize pool and calling at \(Fmt.num(call))%, so a call needs \(Fmt.pct(icmNeed)) equity here: that gap is the risk premium.",
                        evUnit: "% of prizes")
    }

    mutating func caveats() -> Question {
        let items: [(String, [String], String)] = [
            ("With three or more players, which promise of GTO no longer holds?", ["That you can't lose on average", "That it beats bad players", "That it is a fixed strategy", "That it uses mixed frequencies"],
             "In multiway pots the Nash guarantees break down: other players' choices can shift EV away from you, even if you play an equilibrium."),
            ("Two perfect GTO players play a raked cash game heads-up. What happens?", ["Both lose the rake", "The better positional player wins", "They break even", "The rake makes GTO exploitable"],
             "Two equilibrium players break even against each other before rake, so with rake they simply split the cost of it."),
            ("GTO guarantees you can't be exploited by one opponent. What does it not cover?", ["Several players colluding", "A single opponent's best response", "Bluffs at random frequencies", "Short stacks"],
             "The guarantee covers one player deviating. Colluding players deviate together, which equilibrium doesn't protect against."),
            ("In 2017 Libratus played four top pros heads-up no-limit. What was its win rate?", ["147 mbb/hand", "14.7 mbb/hand", "1.47 bb/hand", "Break-even"],
             "Libratus won 147 mbb/hand over 120,000 hands. Cepheus had essentially solved heads-up limit in 2015, and Pluribus beat pros at six-max in 2019."),
            ("Why can the chip-EV answer be wrong in a tournament?", ["Chips aren't worth money one-to-one", "Blinds rise", "Players are tighter", "Equity is lower"],
             "Prize money is paid by finishing position, so the chips you lose cost more than the chips you win: ICM adds a risk premium."),
        ]
        let (prompt, answers, explanation) = pick(items)
        let order = Array(answers.indices).shuffled(using: &rng)
        return fact(prompt, answers: order.map { answers[$0] }, correct: order.firstIndex(of: 0)!, explanation: explanation)
    }
}

// MARK: - Helpers

func equityOf(_ request: EquityRequest, seed: UInt64) async throws -> Double {
    if try EquityCalculator.estimatedExactBoards(request) <= 3_000_000 {
        return try await EquityCalculator.exact(request).equities[0]
    }
    return try await EquityCalculator.monteCarlo(request, trials: 200_000, seed: seed).equities[0]
}

/// Push/fold solutions are reused across questions (one CFR+ solve per stack depth).
actor PushFoldCache {
    static let shared = PushFoldCache()
    private var cache: [Double: PushFoldSolution] = [:]
    static let iterations = 1000

    func solution(stack: Double) -> PushFoldSolution {
        if let s = cache[stack] { return s }
        let s = CFRPlusSolver().solve(stack: stack, iterations: Self.iterations, checkpointEvery: Self.iterations)
        cache[stack] = s
        return s
    }
}
