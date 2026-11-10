import PokerCore

/// "What is your equity?" The player answers with a slider; scoring is by absolute error.
public struct EquityQuizSpot: Hashable, Sendable, Codable {
    public let category: SkillCategory
    public let hero: HoleCards
    public let villain: NamedRange?     // nil -> villainHand
    public let villainHand: HoleCards?
    public let board: CardSet

    public var street: Street { Street.allCases.first { $0.boardCount == board.count }! }
    public var request: EquityRequest {
        EquityRequest(players: [HandRange(hero), villainHand.map { HandRange($0) } ?? villain!.range], board: board)
    }
    public var villainDescription: String { villainHand?.description ?? villain!.name }

    public func solve() async throws -> Double { try await trueEquity(request).equities[0] }
}

public enum EquityQuiz {
    public static let categories: [SkillCategory] = [.preflopMatchups, .flopDraws, .madeHandsVsRanges, .turnDecisions]

    public static func generate(_ category: SkillCategory, seed: UInt64) -> EquityQuizSpot {
        var d = Dealer(rng: Xoshiro256(seed: seed))
        switch category {
        case .flopDraws:
            // Hero holds two suited cards with two more of the suit on the flop (flush draw),
            // villain holds a made pair or better.
            let suit = Suit(rawValue: UInt8(d.rng.next(below: 4)))!
            let hero = d.hand { $0.high.suit == suit && $0.low.suit == suit }
            var boardCards: [Card] = []
            while boardCards.count < 2 {
                let c = Card(Rank(rawValue: UInt8(d.rng.next(below: 13)))!, suit)
                if !d.used.contains(c) { d.used.insert(c); boardCards.append(c) }
            }
            var off = d.card()
            while off.suit == suit { d.used.remove(off); off = d.card() }
            let board = CardSet(boardCards + [off])
            let villain = d.hand { h in
                let ranks = board.map(\.rank)
                return (h.high.rank == h.low.rank || ranks.contains(h.high.rank) || ranks.contains(h.low.rank))
                    && h.high.suit != suit && h.low.suit != suit
            }
            return EquityQuizSpot(category: category, hero: hero, villain: nil, villainHand: villain, board: board)
        case .madeHandsVsRanges:
            let hero = d.hand()
            let board = d.board(3)
            let range = d.pick(Array(NamedRange.presets.dropFirst()))
            return EquityQuizSpot(category: category, hero: hero, villain: range, villainHand: nil, board: board)
        case .turnDecisions:
            let hero = d.hand(), villain = d.hand()
            return EquityQuizSpot(category: category, hero: hero, villain: nil, villainHand: villain, board: d.board(4))
        default:
            let hero = d.hand(), villain = d.hand()
            return EquityQuizSpot(category: .preflopMatchups, hero: hero, villain: nil, villainHand: villain, board: CardSet())
        }
    }

    /// Score for a guess (both as fractions 0...1).
    public static func grade(guess: Double, truth: Double) -> Grade {
        let error = abs(guess - truth) * 100
        let verdict: Grade.Verdict = error <= 2 ? .spotOn : error <= 5 ? .close : error <= 10 ? .off : .wayOff
        let points = max(0, Int((100 - 8 * error).rounded()))
        return Grade(isCorrect: error <= 5, errorPoints: error, points: points, verdict: verdict)
    }
}

/// Outcome of one answer, shared by every drill.
public struct Grade: Hashable, Sendable, Codable {
    public enum Verdict: String, Codable, Sendable {
        case spotOn, close, off, wayOff, correct, incorrect
        public var title: String {
            switch self {
            case .spotOn: "Spot on"
            case .close: "Close"
            case .off: "A bit off"
            case .wayOff: "Way off"
            case .correct: "Correct"
            case .incorrect: "Not quite"
            }
        }
    }
    public let isCorrect: Bool
    /// Equity Quiz: absolute error in percentage points. Pot Odds: EV given up (bb). Range: % wrong.
    public let errorPoints: Double
    public let points: Int
    public let verdict: Verdict
}
