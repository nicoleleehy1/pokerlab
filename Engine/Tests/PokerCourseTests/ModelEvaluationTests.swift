import Testing
import Foundation
import PokerCore
@testable import PokerCourse

@Suite("Evaluating the adaptive model on logged answers")
struct ModelEvaluationTests {
    func event(_ day: Double, _ correct: Bool, p: Double, r: Double? = nil) -> AnswerEvent {
        AnswerEvent(day: day, template: .mdf, correct: correct, lossFraction: correct ? 0 : 0.2, seconds: 5,
                    eloPrediction: p, fsrsRetrievability: r)
    }

    @Test func needsEnoughAnswers() {
        #expect(ModelEvaluation.evaluate((0..<29).map { event(Double($0), true, p: 0.7) }) == nil)
    }

    /// A predictor that ranks every correct answer above every miss scores AUC 1 and beats the
    /// constant baseline; the baseline uses only the earlier answers.
    @Test func perfectPredictorBeatsBaseline() {
        let events = (0..<100).map { i in event(Double(i), i % 3 != 0, p: i % 3 != 0 ? 0.9 : 0.1, r: 0.8) }
        let e = ModelEvaluation.evaluate(events)!
        #expect(e.trainCount == 70)
        #expect(e.elo.count == 30)
        #expect(e.elo.auc == 1)
        #expect(e.elo.logLoss < e.baseline.logLoss)
        #expect(e.elo.brier < e.baseline.brier)
        #expect(e.baseline.auc == 0.5)
        #expect(e.fsrs != nil)
    }

    /// The split is chronological, whatever order the log arrives in.
    @Test func splitIsChronological() {
        var events = (0..<50).map { i in event(Double(i), i >= 35, p: 0.5) }
        events.shuffle()
        let e = ModelEvaluation.evaluate(events)!
        // Train = days 0..34 (all misses), so the baseline predicts the floor rate.
        #expect(abs(e.baseline.logLoss - (-log(0.01))) < 1e-9)
    }

    /// Logging captures the predictions made before the update.
    @Test func logRecordsPriorPredictions() {
        var state = AdaptiveState()
        let first = state.log(.mdf, lossFraction: 0, seconds: 4, at: 10)
        #expect(first.eloPrediction == 0.5)
        #expect(first.fsrsRetrievability == nil)
        let second = state.log(.mdf, lossFraction: 0, seconds: 4, at: 12)
        #expect(second.eloPrediction > 0.5)
        #expect(second.fsrsRetrievability! < 1 && second.fsrsRetrievability! > 0.5)
    }

    @Test func csvRow() {
        let e = event(1.5, true, p: 0.75, r: nil)
        #expect(e.csvRow == "1.50000,mdf,mdf,1,0.00000,5.00,0.75000,")
        #expect(AnswerEvent.csvHeader.split(separator: ",").count == e.csvRow.split(separator: ",", omittingEmptySubsequences: false).count)
    }
}
