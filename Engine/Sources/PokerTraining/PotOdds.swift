import PokerCore

/// Facing a bet: call or fold? Correct when the decision matches the sign of the call's EV.
public struct PotOddsSpot: Hashable, Sendable, Codable {
    public let category: SkillCategory
    public let hero: HoleCards
    public let villain: NamedRange
    public let board: CardSet
    /// Pot before villain's bet, and villain's bet, in big blinds.
    public let pot: Double
    public let bet: Double

    /// Equity needed to break even on a call: bet / (pot + 2 * bet).
    public var requiredEquity: Double { bet / (pot + 2 * bet) }
    public var request: EquityRequest { EquityRequest(players: [HandRange(hero), villain.range], board: board) }

    /// EV of calling relative to folding, in bb, for a given equity (all-in style: no future streets).
    public func callEV(equity: Double) -> Double { equity * (pot + 2 * bet) - bet }

    public func solve() async throws -> Double { try await trueEquity(request).equities[0] }
}

public enum PotOddsDrill {
    public static let categories: [SkillCategory] = [.potOddsPreflop, .potOddsPostflop]
    static let betSizes: [Double] = [0.33, 0.5, 0.75, 1.0, 1.5]

    public static func generate(_ category: SkillCategory, seed: UInt64) -> PotOddsSpot {
        var d = Dealer(rng: Xoshiro256(seed: seed))
        let villain = d.pick(NamedRange.presets)
        let hero = d.hand()
        if category == .potOddsPreflop {
            // Villain shoves; hero closes the action.
            let stack = Double(8 + d.rng.next(below: 13))
            return PotOddsSpot(category: category, hero: hero, villain: villain, board: CardSet(), pot: 1.5 + 1, bet: stack - 1)
        }
        let board = d.board(d.rng.next(below: 2) == 0 ? 3 : 4)
        let pot = Double(4 + d.rng.next(below: 37))
        let fraction = d.pick(betSizes)
        return PotOddsSpot(category: .potOddsPostflop, hero: hero, villain: villain, board: board,
                           pot: pot, bet: (pot * fraction * 2).rounded() / 2)
    }

    public static func grade(called: Bool, spot: PotOddsSpot, equity: Double) -> Grade {
        let ev = spot.callEV(equity: equity)
        let shouldCall = ev >= 0
        let correct = called == shouldCall || abs(ev) < 0.05 // indifferent spots count either way
        let evLost = correct ? 0 : abs(ev)
        return Grade(isCorrect: correct, errorPoints: evLost, points: correct ? 100 : 0,
                     verdict: correct ? .correct : .incorrect)
    }
}
