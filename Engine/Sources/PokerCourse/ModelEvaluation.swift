import Foundation

/// One real answer, logged with what the adaptive model predicted *before* it was given.
public struct AnswerEvent: Hashable, Sendable, Codable {
    public let day: Double                 // fractional days (any fixed epoch)
    public let template: TemplateID
    public let correct: Bool
    public let lossFraction: Double
    public let seconds: Double?
    /// Elo's predicted probability of a correct answer.
    public let eloPrediction: Double
    /// FSRS retrievability of the template at answer time (nil on a template's first review).
    public let fsrsRetrievability: Double?

    public init(day: Double, template: TemplateID, correct: Bool, lossFraction: Double, seconds: Double?,
                eloPrediction: Double, fsrsRetrievability: Double?) {
        self.day = day; self.template = template; self.correct = correct; self.lossFraction = lossFraction
        self.seconds = seconds; self.eloPrediction = eloPrediction; self.fsrsRetrievability = fsrsRetrievability
    }

    public static let csvHeader = "day,template,concept,correct,loss_fraction,seconds,elo_prediction,fsrs_retrievability"
    public var csvRow: String {
        [String(format: "%.5f", day), template.rawValue, template.concept.rawValue, correct ? "1" : "0",
         String(format: "%.5f", lossFraction), seconds.map { String(format: "%.2f", $0) } ?? "",
         String(format: "%.5f", eloPrediction), fsrsRetrievability.map { String(format: "%.5f", $0) } ?? ""].joined(separator: ",")
    }
}

extension AdaptiveState {
    /// Records an answer and returns the event with the predictions made before the update.
    public mutating func log(_ t: TemplateID, lossFraction: Double, seconds: Double?, at now: Double) -> AnswerEvent {
        let event = AnswerEvent(day: now, template: t, correct: Grading.isCorrect(lossFraction: lossFraction),
                                lossFraction: lossFraction, seconds: seconds, eloPrediction: elo.predict(t),
                                fsrsRetrievability: cards[t]?.retrievability(at: now))
        record(t, lossFraction: lossFraction, seconds: seconds, at: now)
        return event
    }
}

/// Held-out evaluation of the adaptive model on logged answers: answers are sorted by time, the
/// earlier part fits the baseline (its overall success rate), and the later part is scored.
/// Predictions were made online before each answer, so the later part is genuinely unseen.
public struct ModelEvaluation: Hashable, Sendable {
    public struct Scores: Hashable, Sendable {
        public let count: Int
        public let auc: Double
        public let logLoss: Double
        public let brier: Double
    }

    public let trainCount: Int
    public let elo: Scores
    public let baseline: Scores
    /// FSRS retrievability scored on later reviews of templates seen before (nil if too few).
    public let fsrs: Scores?

    /// Minimum answers before an evaluation is meaningful.
    public static let minimumAnswers = 30

    public static func evaluate(_ events: [AnswerEvent], testFraction: Double = 0.3) -> ModelEvaluation? {
        guard events.count >= minimumAnswers else { return nil }
        let sorted = events.sorted { $0.day < $1.day }
        let split = Int((Double(sorted.count) * (1 - testFraction)).rounded())
        let train = sorted[..<split], test = Array(sorted[split...])
        let y = test.map { $0.correct ? 1.0 : 0.0 }
        // Baseline: the earlier answers' success rate, kept off 0 and 1 so log loss stays finite.
        let rate = min(max(Double(train.filter(\.correct).count) / Double(train.count), 0.01), 0.99)
        func scores(_ p: [Double], _ y: [Double]) -> Scores {
            Scores(count: y.count, auc: PredictionMetrics.auc(p, y), logLoss: PredictionMetrics.logLoss(p, y),
                   brier: zip(p, y).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) } / Double(max(y.count, 1)))
        }
        let reviews = test.filter { $0.fsrsRetrievability != nil }
        let fsrs = reviews.count >= 10 ? scores(reviews.map { $0.fsrsRetrievability! }, reviews.map { $0.correct ? 1.0 : 0.0 }) : nil
        return ModelEvaluation(trainCount: train.count, elo: scores(test.map(\.eloPrediction), y),
                               baseline: scores(Array(repeating: rate, count: y.count), y), fsrs: fsrs)
    }
}
