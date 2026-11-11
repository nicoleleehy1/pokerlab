import Foundation

// MARK: - FSRS

/// FSRS-4.5 memory model (Ye et al.; open-spaced-repetition). A card here is a spot template:
/// every review deals a fresh spot, so what's scheduled is the concept, not one hand.
///
/// Retrievability after t days: R = (1 + F t / S)^D with D = -0.5, F = 19/81, so R = 90%
/// exactly when t = S. Stability and difficulty update after each review from the grade.
public struct FSRS: Hashable, Sendable, Codable {
    public enum Rating: Int, Hashable, Sendable, Codable, CaseIterable { case again = 1, hard, good, easy }

    /// Default FSRS-4.5 weights (fitted on the Anki benchmark; personalisable later).
    public var w: [Double] = [0.4872, 1.4003, 3.7145, 13.8206, 5.1618, 1.2298, 0.8975, 0.031, 1.6474, 0.1367,
                              1.0461, 2.1072, 0.0793, 0.3246, 1.587, 0.2272, 2.8755]
    public var desiredRetention = 0.9

    public init() {}

    static let decay = -0.5
    static let factor = 19.0 / 81

    public static func retrievability(elapsedDays t: Double, stability s: Double) -> Double {
        pow(1 + factor * max(t, 0) / s, decay)
    }

    /// Days until retrievability falls to `desiredRetention`.
    public func interval(stability s: Double) -> Double {
        s / Self.factor * (pow(desiredRetention, 1 / Self.decay) - 1)
    }

    func initialStability(_ g: Rating) -> Double { w[g.rawValue - 1] }
    func initialDifficulty(_ g: Rating) -> Double { clampD(w[4] - Double(g.rawValue - 3) * w[5]) }
    func clampD(_ d: Double) -> Double { min(10, max(1, d)) }

    func nextDifficulty(_ d: Double, _ g: Rating) -> Double {
        let d1 = d - w[6] * Double(g.rawValue - 3)
        return clampD(w[7] * initialDifficulty(.easy) + (1 - w[7]) * d1)
    }

    func stabilityAfterSuccess(_ d: Double, _ s: Double, _ r: Double, _ g: Rating) -> Double {
        let hard = g == .hard ? w[15] : 1, easy = g == .easy ? w[16] : 1
        return s * (exp(w[8]) * (11 - d) * pow(s, -w[9]) * (exp(w[10] * (1 - r)) - 1) * hard * easy + 1)
    }

    func stabilityAfterFailure(_ d: Double, _ s: Double, _ r: Double) -> Double {
        min(s, w[11] * pow(d, -w[12]) * (pow(s + 1, w[13]) - 1) * exp(w[14] * (1 - r)))
    }

    /// Memory state of one template.
    public struct Card: Hashable, Sendable, Codable {
        public var stability = 0.0
        public var difficulty = 0.0
        public var lastReview: Double?      // days (any epoch, e.g. Date.timeIntervalSinceReferenceDate / 86400)
        public var due = 0.0
        public var reps = 0
        public var lapses = 0
        public init() {}

        public func retrievability(at now: Double) -> Double? {
            guard let last = lastReview, stability > 0 else { return nil }
            return FSRS.retrievability(elapsedDays: now - last, stability: stability)
        }
    }

    public func review(_ card: Card, rating g: Rating, at now: Double) -> Card {
        var c = card
        if let last = card.lastReview, card.stability > 0 {
            let r = Self.retrievability(elapsedDays: now - last, stability: card.stability)
            c.stability = g == .again ? stabilityAfterFailure(card.difficulty, card.stability, r)
                                      : stabilityAfterSuccess(card.difficulty, card.stability, r, g)
            c.difficulty = nextDifficulty(card.difficulty, g)
        } else {
            c.stability = initialStability(g)
            c.difficulty = initialDifficulty(g)
        }
        if g == .again { c.lapses += 1 }
        c.reps += 1
        c.lastReview = now
        // A lapse comes back in the next session (5 minutes); otherwise at least a day out.
        c.due = now + (g == .again ? 5.0 / 1440 : max(1, interval(stability: c.stability).rounded()))
        return c
    }

    /// Maps an answer to a grade: EV loss decides Again/Hard/Good, speed upgrades Good to Easy.
    /// Again: mistake or blunder (> 5% of the pot). Hard: inaccuracy (1-5%). Good: correct.
    /// Easy: correct in under 8 seconds.
    public static func rating(lossFraction: Double, seconds: Double?) -> Rating {
        switch Grading.verdict(lossFraction: lossFraction) {
        case .mistake, .blunder: .again
        case .inaccuracy: .hard
        case .best, .correct: (seconds.map { $0 < 8 } ?? false) ? .easy : .good
        }
    }
}

// MARK: - Elo

/// Per-concept Elo (Pelánek): P(correct) = σ(θ_concept − d_template), with step size
/// K = a / (1 + b n) so early answers move estimates more. Answers give partial credit
/// exp(−EV loss / τ) instead of a hard right/wrong.
public struct EloModel: Hashable, Sendable, Codable {
    public var skill: [Concept: Double] = [:]
    public var difficulty: [TemplateID: Double] = [:]
    public var answers: [Concept: Int] = [:]
    public var itemAnswers: [TemplateID: Int] = [:]

    public static let a = 1.0, b = 0.05
    /// Partial-credit scale: an answer losing 5% of the pot scores e^-1 ≈ 0.37.
    public static let tau = 0.05

    public init() {}

    static func sigmoid(_ x: Double) -> Double { 1 / (1 + exp(-x)) }

    public func predict(_ t: TemplateID) -> Double {
        Self.sigmoid((skill[t.concept] ?? 0) - (difficulty[t] ?? 0))
    }

    public static func score(lossFraction: Double) -> Double { exp(-max(0, lossFraction) / tau) }

    public mutating func record(_ t: TemplateID, lossFraction: Double) {
        let p = predict(t), s = Self.score(lossFraction: lossFraction)
        let n = answers[t.concept] ?? 0, m = itemAnswers[t] ?? 0
        skill[t.concept, default: 0] += Self.a / (1 + Self.b * Double(n)) * (s - p)
        difficulty[t, default: 0] -= Self.a / (1 + Self.b * Double(m)) * (s - p)
        answers[t.concept] = n + 1
        itemAnswers[t] = m + 1
    }

    /// Mastery shown per concept: predicted success on an average-difficulty template.
    public func mastery(_ c: Concept) -> Double { Self.sigmoid(skill[c] ?? 0) }
}

// MARK: - Adaptive state

/// FSRS memory per template plus Elo per concept; picks what to practise next.
public struct AdaptiveState: Hashable, Sendable, Codable {
    public var cards: [TemplateID: FSRS.Card] = [:]
    public var elo = EloModel()
    public var fsrs = FSRS()
    /// Predicted success the selector aims for.
    public static let targetSuccess = 0.75

    public init() {}

    public mutating func record(_ t: TemplateID, lossFraction: Double, seconds: Double?, at now: Double) {
        let rating = FSRS.rating(lossFraction: lossFraction, seconds: seconds)
        cards[t] = fsrs.review(cards[t] ?? FSRS.Card(), rating: rating, at: now)
        elo.record(t, lossFraction: lossFraction)
    }

    public func due(at now: Double) -> [TemplateID] {
        cards.filter { $0.value.due <= now }.sorted { $0.value.due < $1.value.due }.map(\.key)
    }

    /// Next templates for a session of `count` questions from `pool` (templates the learner
    /// has unlocked): overdue reviews first (most overdue first), then the templates whose
    /// predicted success is closest to 75%. The same template never appears twice in a row.
    public func plan(count: Int, pool: [TemplateID], at now: Double) -> [TemplateID] {
        guard !pool.isEmpty else { return [] }
        var out: [TemplateID] = []
        var uses: [TemplateID: Int] = [:]
        var dueQueue = due(at: now).filter(pool.contains)
        while out.count < count {
            let pick: TemplateID
            if let d = dueQueue.first(where: { $0 != out.last }) {
                pick = d
                dueQueue.removeAll { $0 == d }
            } else {
                let options = pool.count > 1 ? pool.filter { $0 != out.last } : pool
                // Distance from the target, plus a small penalty per use so a session mixes templates.
                func cost(_ t: TemplateID) -> Double { abs(elo.predict(t) - Self.targetSuccess) + 0.05 * Double(uses[t] ?? 0) }
                pick = options.min { cost($0) != cost($1) ? cost($0) < cost($1) : $0.rawValue < $1.rawValue }!
            }
            out.append(pick)
            uses[pick, default: 0] += 1
        }
        return out
    }
}

// MARK: - Evaluation

/// Log loss and AUC of predicted probabilities against (partial-credit) outcomes ≥ 0.5.
public enum PredictionMetrics {
    public static func logLoss(_ p: [Double], _ y: [Double]) -> Double {
        zip(p, y).reduce(0) { acc, e in
            let q = min(max(e.0, 1e-9), 1 - 1e-9)
            return acc - (e.1 * log(q) + (1 - e.1) * log(1 - q))
        } / Double(max(p.count, 1))
    }

    public static func auc(_ p: [Double], _ y: [Double]) -> Double {
        let pos = zip(p, y).filter { $0.1 >= 0.5 }.map(\.0), neg = zip(p, y).filter { $0.1 < 0.5 }.map(\.0)
        guard !pos.isEmpty, !neg.isEmpty else { return 0.5 }
        var wins = 0.0
        for a in pos { for b in neg { wins += a > b ? 1 : (a == b ? 0.5 : 0) } }
        return wins / Double(pos.count * neg.count)
    }
}

extension Concept: CodingKeyRepresentable {}
extension TemplateID: CodingKeyRepresentable {}
