import Testing
import Foundation
import PokerCore
@testable import PokerCourse

@Suite("FSRS scheduling")
struct FSRSTests {
    let fsrs = FSRS()

    @Test func retrievabilityIsNinetyPercentAtStability() {
        #expect(abs(FSRS.retrievability(elapsedDays: 7, stability: 7) - 0.9) < 1e-9)
        #expect(abs(fsrs.interval(stability: 7) - 7) < 1e-9)
        #expect(FSRS.retrievability(elapsedDays: 0, stability: 3) == 1)
    }

    @Test func firstReviewUsesInitialStability() {
        let c = fsrs.review(.init(), rating: .good, at: 100)
        #expect(abs(c.stability - 3.7145) < 1e-9)
        #expect(c.due == 104)                                  // interval 3.7 days, rounded
        #expect(c.difficulty >= 1 && c.difficulty <= 10)
    }

    @Test func successesGrowIntervalsAndFailuresShrinkThem() {
        var c = fsrs.review(.init(), rating: .good, at: 0)
        var last = c.stability
        for _ in 0..<4 {
            c = fsrs.review(c, rating: .good, at: c.due)
            #expect(c.stability > last)
            last = c.stability
        }
        let failed = fsrs.review(c, rating: .again, at: c.due)
        #expect(failed.stability < c.stability)
        #expect(failed.due - c.due < 1)
        #expect(failed.lapses == 1)
        let easy = fsrs.review(c, rating: .easy, at: c.due), hard = fsrs.review(c, rating: .hard, at: c.due)
        #expect(easy.stability > hard.stability)
    }

    @Test func evLossMapsToRatings() {
        #expect(FSRS.rating(lossFraction: 0, seconds: 3) == .easy)
        #expect(FSRS.rating(lossFraction: 0.005, seconds: 20) == .good)
        #expect(FSRS.rating(lossFraction: 0.03, seconds: 3) == .hard)
        #expect(FSRS.rating(lossFraction: 0.2, seconds: 3) == .again)
    }
}

@Suite("Elo and question selection")
struct EloTests {
    @Test func partialCredit() {
        #expect(EloModel.score(lossFraction: 0) == 1)
        #expect(abs(EloModel.score(lossFraction: 0.05) - exp(-1)) < 1e-12)
    }

    @Test func estimatesMoveTowardOutcomes() {
        var elo = EloModel()
        #expect(elo.predict(.mdf) == 0.5)
        for _ in 0..<10 { elo.record(.mdf, lossFraction: 0) }
        #expect(elo.predict(.mdf) > 0.8)
        #expect(elo.mastery(.mdf) > 0.7)
        for _ in 0..<10 { elo.record(.pushFold, lossFraction: 0.3) }
        #expect(elo.predict(.pushFold) < 0.2)
    }

    @Test func planServesDueReviewsFirstThenTargetsSeventyFivePercent() {
        var state = AdaptiveState()
        state.elo.skill[.mdf] = 3          // ~95%: too easy
        state.elo.skill[.bluffRatio] = 1.1 // ~75%
        state.elo.skill[.pushFold] = -2    // ~12%: too hard
        state.cards[.icmCall] = { var c = FSRS.Card(); c.stability = 1; c.lastReview = 0; c.due = 1; return c }()
        let plan = state.plan(count: 4, pool: [.mdf, .bluffRatio, .pushFold, .icmCall], at: 10)
        #expect(plan.first == .icmCall)
        #expect(plan[1] == .bluffRatio)
        for i in 1..<plan.count { #expect(plan[i] != plan[i - 1]) }
    }

    /// Held-out evaluation on a simulated learner: per-concept skills and per-template
    /// difficulties drawn at random, outcomes Bernoulli from the true model, learning over
    /// time. Predictions made online (before each answer) on the later half must beat a
    /// constant baseline fitted on the earlier half.
    @Test func eloBeatsConstantBaselineOnHeldOutAnswers() {
        var rng = Xoshiro256(seed: 2024)
        let templates = TemplateID.allCases
        var trueSkill = Dictionary(uniqueKeysWithValues: Concept.allCases.map { ($0, rng.nextUnit() * 3 - 1.5) })
        let trueDifficulty = Dictionary(uniqueKeysWithValues: templates.map { ($0, rng.nextUnit() * 3 - 1.5) })
        var state = AdaptiveState()
        var predictions: [Double] = [], outcomes: [Double] = []
        for step in 0..<3000 {
            let t = templates[Int(rng.next(below: UInt64(templates.count)))]
            let p = 1 / (1 + exp(-(trueSkill[t.concept]! - trueDifficulty[t]!)))
            let correct = rng.nextUnit() < p
            predictions.append(state.elo.predict(t))
            outcomes.append(correct ? 1 : 0)
            state.record(t, lossFraction: correct ? 0 : 0.2, seconds: 10, at: Double(step) / 50)
            trueSkill[t.concept]! += 0.002          // slow learning
        }
        let half = predictions.count / 2
        let base = outcomes[..<half].reduce(0, +) / Double(half)
        let heldP = Array(predictions[half...]), heldY = Array(outcomes[half...])
        let eloLoss = PredictionMetrics.logLoss(heldP, heldY)
        let baseLoss = PredictionMetrics.logLoss(Array(repeating: base, count: heldY.count), heldY)
        let auc = PredictionMetrics.auc(heldP, heldY)
        #expect(eloLoss < baseLoss, "Elo log loss \(eloLoss) vs baseline \(baseLoss)")
        #expect(auc > 0.65, "AUC \(auc)")
        print("Simulated learner, held-out half: Elo log loss \(eloLoss), constant baseline \(baseLoss), AUC \(auc)")
    }

    @Test func stateRoundTripsThroughJSON() throws {
        var state = AdaptiveState()
        state.record(.mdf, lossFraction: 0, seconds: 4, at: 1)
        state.record(.pushFold, lossFraction: 0.1, seconds: 4, at: 1)
        let data = try JSONEncoder().encode(state)
        #expect(try JSONDecoder().decode(AdaptiveState.self, from: data) == state)
    }
}
