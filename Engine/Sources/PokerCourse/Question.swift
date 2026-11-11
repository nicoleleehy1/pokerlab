import PokerCore

/// One generated course question. Every option carries its expected value, so grading is by
/// EV loss rather than by matching a single "right" answer.
///
/// Two kinds share this model:
/// - **Decisions** (call/fold, push/fold, ...): `ev` is the action's EV in big blinds and
///   `pot` is the pot the decision is made in, so EV loss can be reported as % of pot.
/// - **Estimates** (equity, MDF, ...): `ev` is minus the option's distance from the true value
///   in percentage points and `pot` is 100, so "EV loss" is the extra error in points.
public struct Question: Hashable, Sendable, Identifiable {
    public struct Option: Hashable, Sendable {
        public let label: String
        public let ev: Double
        public init(_ label: String, ev: Double) { self.label = label; self.ev = ev }
    }

    public enum Kind: String, Hashable, Sendable, Codable { case decision, estimate }

    public struct Fact: Hashable, Sendable {
        public let label: String
        public let value: String
        public init(_ label: String, _ value: String) { self.label = label; self.value = value }
    }

    public let id: String
    public let concept: Concept
    public let kind: Kind
    public let prompt: String
    public var hero: [Card] = []
    public var villain: [Card] = []
    public var board: [Card] = []
    public var facts: [Fact] = []
    public let options: [Option]
    public let pot: Double
    /// Explanation shown after answering, with the numbers that decide the spot.
    public let explanation: String
    /// Unit of `ev` for display ("bb", "points", "% of prizes").
    public let evUnit: String

    public init(id: String, concept: Concept, kind: Kind, prompt: String, hero: [Card] = [], villain: [Card] = [],
                board: [Card] = [], facts: [Fact] = [], options: [Option], pot: Double, explanation: String,
                evUnit: String? = nil) {
        precondition(options.count >= 2, "a question needs at least two options")
        precondition(pot > 0)
        self.id = id; self.concept = concept; self.kind = kind; self.prompt = prompt
        self.hero = hero; self.villain = villain; self.board = board; self.facts = facts
        self.options = options; self.pot = pot; self.explanation = explanation
        self.evUnit = evUnit ?? (kind == .decision ? "bb" : "points")
    }

    public var bestEV: Double { options.map(\.ev).max()! }

    /// Options graded as correct: within the equal-EV tolerance of the best.
    public var correctOptions: Set<Int> {
        Set(options.indices.filter { Grading.isCorrect(lossFraction: lossFraction(of: $0)) })
    }

    /// EV given up by choosing option `i`, in the question's unit.
    public func evLoss(of i: Int) -> Double { max(0, bestEV - options[i].ev) }
    /// EV loss as a fraction of the pot.
    public func lossFraction(of i: Int) -> Double { evLoss(of: i) / pot }

    public func grade(_ choice: Int) -> GradedAnswer {
        GradedAnswer(choice: choice, evLoss: evLoss(of: choice), lossFraction: lossFraction(of: choice),
                     verdict: Grading.verdict(lossFraction: lossFraction(of: choice)))
    }
}

/// The result of answering one question.
public struct GradedAnswer: Hashable, Sendable, Codable {
    public let choice: Int
    public let evLoss: Double
    public let lossFraction: Double
    public let verdict: Grading.Verdict
    public var isCorrect: Bool { verdict.isCorrect }
}

/// EV-loss grading with published thresholds. All thresholds are fractions of the pot (for
/// estimate questions, percentage points of error beyond the best option).
///
/// | Verdict     | EV loss          |
/// |-------------|------------------|
/// | Best        | 0                |
/// | Correct     | ≤ 1% of the pot  (equal EV: counts as correct) |
/// | Inaccuracy  | ≤ 5% of the pot  |
/// | Mistake     | ≤ 15% of the pot |
/// | Blunder     | > 15% of the pot |
///
/// The 1% tolerance is deliberately wider than solver noise (river solves here stop at 0.3%
/// pot exploitability), so two actions a solver mixes between both grade as correct.
public enum Grading {
    public static let equalEVTolerance = 0.01
    public static let inaccuracyLimit = 0.05
    public static let mistakeLimit = 0.15

    public enum Verdict: String, Hashable, Sendable, Codable, CaseIterable {
        case best, correct, inaccuracy, mistake, blunder
        public var isCorrect: Bool { self == .best || self == .correct }
        public var title: String {
            switch self {
            case .best: "Best"
            case .correct: "Correct"
            case .inaccuracy: "Inaccuracy"
            case .mistake: "Mistake"
            case .blunder: "Blunder"
            }
        }
    }

    public static func isCorrect(lossFraction: Double) -> Bool { lossFraction <= equalEVTolerance + 1e-12 }

    public static func verdict(lossFraction f: Double) -> Verdict {
        if f <= 1e-9 { return .best }
        if f <= equalEVTolerance + 1e-12 { return .correct }
        if f <= inaccuracyLimit { return .inaccuracy }
        if f <= mistakeLimit { return .mistake }
        return .blunder
    }
}

// MARK: - Formatting helpers

enum Fmt {
    static func pct(_ x: Double, _ digits: Int = 1) -> String {
        let scale = pow10(digits)
        let v = (x * 100 * scale).rounded() / scale
        return digits == 0 ? "\(Int(v))%" : "\(trim(v, digits))%"
    }
    static func bb(_ x: Double) -> String { "\(trim((x * 10).rounded() / 10, 1)) bb" }
    static func num(_ x: Double, _ digits: Int = 1) -> String { trim((x * pow10(digits)).rounded() / pow10(digits), digits) }

    static func trim(_ v: Double, _ digits: Int) -> String {
        if v == v.rounded() { return String(Int(v)) }
        var s = String(v)
        if let dot = s.firstIndex(of: ".") {
            let end = s.index(dot, offsetBy: digits + 1, limitedBy: s.endIndex) ?? s.endIndex
            s = String(s[..<end])
        }
        return s
    }
    static func pow10(_ d: Int) -> Double { (0..<d).reduce(1.0) { a, _ in a * 10 } }
    static func signed(_ x: Double) -> String { (x >= 0 ? "+" : "−") + bb(abs(x)) }
}
