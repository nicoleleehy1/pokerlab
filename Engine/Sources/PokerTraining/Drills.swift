import PokerCore
import PokerSolver

/// The three drill modes.
public enum DrillKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case equityQuiz, potOdds, rangeTrainer
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .equityQuiz: "Equity Quiz"
        case .potOdds: "Pot Odds"
        case .rangeTrainer: "Range Trainer"
        }
    }
}

public enum Street: String, Codable, Sendable, CaseIterable {
    case preflop, flop, turn, river
    public var boardCount: Int { [0, 3, 4, 5][Street.allCases.firstIndex(of: self)!] }
}

/// Named villain ranges used by the drills (standard-ish study ranges, not solver output).
public struct NamedRange: Hashable, Sendable, Codable {
    public let name: String
    public let notation: String
    public var range: HandRange { (try? HandRange(notation)) ?? .all }

    public static let presets: [NamedRange] = [
        NamedRange(name: "Any two cards", notation: "random"),
        NamedRange(name: "Tight open", notation: "77+, ATs+, KJs+, QJs, AJo+, KQo"),
        NamedRange(name: "Wide open", notation: "22+, A2s+, K8s+, Q9s+, J9s+, T8s+, 98s, 87s, 76s, A8o+, KTo+, QTo+, JTo"),
        NamedRange(name: "3-bet", notation: "TT+, AQs+, AKo, A5s-A4s"),
        NamedRange(name: "Big pairs", notation: "QQ+"),
    ]
}

/// Categories the spaced-repetition tracker schedules.
public enum SkillCategory: String, CaseIterable, Codable, Sendable {
    case preflopMatchups, flopDraws, madeHandsVsRanges, turnDecisions, potOddsPreflop, potOddsPostflop, pushRanges, callRanges

    public var title: String {
        switch self {
        case .preflopMatchups: "Preflop matchups"
        case .flopDraws: "Flop draws"
        case .madeHandsVsRanges: "Made hands vs ranges"
        case .turnDecisions: "Turn spots"
        case .potOddsPreflop: "Pot odds preflop"
        case .potOddsPostflop: "Pot odds postflop"
        case .pushRanges: "Shove ranges"
        case .callRanges: "Call ranges"
        }
    }

    public var kind: DrillKind {
        switch self {
        case .preflopMatchups, .flopDraws, .madeHandsVsRanges, .turnDecisions: .equityQuiz
        case .potOddsPreflop, .potOddsPostflop: .potOdds
        case .pushRanges, .callRanges: .rangeTrainer
        }
    }
}

// MARK: - Shared dealing helpers

struct Dealer {
    var rng: Xoshiro256
    var used = CardSet()

    mutating func card() -> Card {
        while true {
            let c = Card(rawValue: UInt8(rng.next(below: 52)))
            if !used.contains(c) { used.insert(c); return c }
        }
    }
    mutating func hand() -> HoleCards { HoleCards(card(), card()) }
    mutating func board(_ n: Int) -> CardSet { CardSet((0..<n).map { _ in card() }) }
    mutating func pick<T>(_ xs: [T]) -> T { xs[Int(rng.next(below: UInt64(xs.count)))] }

    /// Deals a hand whose cards satisfy `predicate`, without consuming cards on failures.
    mutating func hand(where predicate: (HoleCards) -> Bool) -> HoleCards {
        while true {
            let a = Card(rawValue: UInt8(rng.next(below: 52))), b = Card(rawValue: UInt8(rng.next(below: 52)))
            guard a != b, !used.contains(a), !used.contains(b) else { continue }
            let h = HoleCards(a, b)
            if predicate(h) { used.insert(a); used.insert(b); return h }
        }
    }
}

/// Exact when cheap, otherwise a large Monte Carlo run (standard error well under 0.2%).
func trueEquity(_ request: EquityRequest) async throws -> EquitySnapshot {
    if try EquityCalculator.estimatedExactBoards(request) <= 3_000_000 {
        return try await EquityCalculator.exact(request)
    }
    return try await EquityCalculator.monteCarlo(request, trials: 400_000, seed: 0xC0FFEE)
}
