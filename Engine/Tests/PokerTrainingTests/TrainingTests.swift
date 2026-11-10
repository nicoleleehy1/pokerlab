import Testing
import PokerCore
import PokerSolver
@testable import PokerTraining

@Suite("Equity Quiz")
struct EquityQuizTests {
    @Test("Generators are deterministic and valid", arguments: EquityQuiz.categories)
    func generate(_ category: SkillCategory) throws {
        for seed in 0..<200 as Range<UInt64> {
            let a = EquityQuiz.generate(category, seed: seed)
            #expect(a == EquityQuiz.generate(category, seed: seed))
            #expect(a.category == category)
            // No card is dealt twice.
            var used = a.board
            #expect(!used.intersects(a.hero.cardSet)); used = used.union(a.hero.cardSet)
            if let v = a.villainHand { #expect(!used.intersects(v.cardSet)) }
            #expect(try EquityCalculator.estimatedExactBoards(a.request) > 0)
        }
    }

    @Test func flopDrawSpotsReallyAreFlushDraws() {
        for seed in 0..<100 as Range<UInt64> {
            let s = EquityQuiz.generate(.flopDraws, seed: seed)
            let suit = s.hero.high.suit
            #expect(s.hero.low.suit == suit)
            #expect(s.board.count == 3)
            #expect(s.board.filter { $0.suit == suit }.count == 2)
        }
    }

    @Test func gradingBands() {
        #expect(EquityQuiz.grade(guess: 0.50, truth: 0.51).verdict == .spotOn)
        #expect(EquityQuiz.grade(guess: 0.50, truth: 0.54).verdict == .close)
        #expect(EquityQuiz.grade(guess: 0.50, truth: 0.58).verdict == .off)
        #expect(EquityQuiz.grade(guess: 0.20, truth: 0.80).verdict == .wayOff)
        #expect(EquityQuiz.grade(guess: 0.5, truth: 0.5).points == 100)
        #expect(EquityQuiz.grade(guess: 0.2, truth: 0.8).points == 0)
        #expect(EquityQuiz.grade(guess: 0.5, truth: 0.53).isCorrect)
        #expect(!EquityQuiz.grade(guess: 0.5, truth: 0.56).isCorrect)
    }

    @Test func solveMatchesTheEngine() async throws {
        let spot = EquityQuiz.generate(.turnDecisions, seed: 3)
        let truth = try await spot.solve()
        let exact = try await EquityCalculator.exact(spot.request)
        #expect(truth == exact.equities[0])
    }
}

@Suite("Pot Odds Drill")
struct PotOddsTests {
    @Test func requiredEquityAndEV() {
        let spot = PotOddsSpot(category: .potOddsPostflop, hero: HoleCards("AhKh")!, villain: NamedRange.presets[0],
                               board: CardSet(parsing: "2h7h9c")!, pot: 10, bet: 5)
        #expect(abs(spot.requiredEquity - 0.25) < 1e-12)       // 5 / (10 + 5 + 5)
        #expect(abs(spot.callEV(equity: 0.25)) < 1e-12)
        #expect(spot.callEV(equity: 0.5) == 5)
    }

    @Test func gradingUsesTheSignOfEV() {
        let spot = PotOddsSpot(category: .potOddsPostflop, hero: HoleCards("AhKh")!, villain: NamedRange.presets[0],
                               board: CardSet(parsing: "2h7h9c")!, pot: 10, bet: 10)  // needs 33.3%
        #expect(PotOddsDrill.grade(called: true, spot: spot, equity: 0.45).isCorrect)
        #expect(!PotOddsDrill.grade(called: false, spot: spot, equity: 0.45).isCorrect)
        let miss = PotOddsDrill.grade(called: true, spot: spot, equity: 0.20)
        #expect(!miss.isCorrect)
        #expect(abs(miss.errorPoints - 4) < 1e-9)  // EV of the bad call: 0.2 * 30 - 10 = -4
        // Near-indifferent spots accept either answer.
        #expect(PotOddsDrill.grade(called: false, spot: spot, equity: 1.0 / 3.0 + 0.001).isCorrect)
    }

    @Test("Generated spots are sane", arguments: PotOddsDrill.categories)
    func generate(_ c: SkillCategory) {
        for seed in 0..<200 as Range<UInt64> {
            let s = PotOddsDrill.generate(c, seed: seed)
            #expect(s == PotOddsDrill.generate(c, seed: seed))
            #expect(s.bet > 0 && s.pot > 0)
            #expect(s.requiredEquity > 0 && s.requiredEquity < 0.5)
            #expect(c == .potOddsPreflop ? s.board.isEmpty : (s.board.count == 3 || s.board.count == 4))
            #expect(!s.board.intersects(s.hero.cardSet))
        }
    }
}

@Suite("Range Trainer")
struct RangeTrainerTests {
    @Test func perfectAndEmptyPaintings() async {
        let charts = PushFoldCharts(iterations: 1000)
        let spot = RangeTrainerSpot(category: .pushRanges, role: .smallBlindShove, stack: 10)
        let ref = await RangeTrainer.reference(for: spot, charts: charts)
        #expect(RangeTrainer.compare(painted: ref, reference: ref).accuracy == 1)
        let empty = RangeTrainer.compare(painted: [], reference: ref)
        // Painting nothing scores the fraction of combos that are correctly folded (~42% at 10 bb).
        #expect(empty.accuracy > 0.35 && empty.accuracy < 0.5)
        #expect(empty.missed.count == ref.count)
        #expect(RangeTrainer.grade(empty).isCorrect == false)
    }

    @Test func accuracyIsComboWeighted() {
        let ref: Set<HandClass> = [HandClass("AKo")!]                 // 12 combos
        let c = RangeTrainer.compare(painted: [HandClass("AKs")!], reference: ref)  // misses 12, adds 4
        #expect(abs(c.accuracy - Double(1326 - 16) / 1326) < 1e-12)
        #expect(c.missed == [HandClass("AKo")!])
        #expect(c.extra == [HandClass("AKs")!])
    }

    @Test func callRangesAreTighterThanShoveRanges() async {
        let charts = PushFoldCharts(iterations: 1000)
        let push = await RangeTrainer.reference(for: RangeTrainerSpot(category: .pushRanges, role: .smallBlindShove, stack: 12), charts: charts)
        let call = await RangeTrainer.reference(for: RangeTrainerSpot(category: .callRanges, role: .bigBlindCall, stack: 12), charts: charts)
        #expect(call.count < push.count)
        #expect(call.isSubset(of: push.union(call)))
    }
}

@Suite("Progress and spaced repetition")
struct ProgressTests {
    @Test func leitnerPromotesAndDemotes() {
        var s = SkillScheduler(categories: [.flopDraws, .turnDecisions])
        s.record(.flopDraws, correct: true)
        s.record(.flopDraws, correct: true)
        #expect(s.entries[.flopDraws]!.box == 2)
        s.record(.flopDraws, correct: false)
        #expect(s.entries[.flopDraws]!.box == 0)
        #expect(s.entries[.flopDraws]!.attempts == 3)
        #expect(abs(s.entries[.flopDraws]!.accuracy - 2.0 / 3.0) < 1e-12)
    }

    @Test func schedulerPrefersWeakCategories() {
        var s = SkillScheduler(categories: [.flopDraws, .turnDecisions])
        for _ in 0..<3 { s.record(.flopDraws, correct: true) }   // box 3, due later
        s.record(.turnDecisions, correct: false)                  // box 0, due next
        #expect(s.next() == .turnDecisions)
        #expect(s.leaks.first?.0 == .turnDecisions)
    }

    @Test func schedulerRespectsDrillKind() {
        let s = SkillScheduler()
        for seed in 0..<20 as Range<UInt64> { #expect(s.next(in: .potOdds, seed: seed).kind == .potOdds) }
    }

    @Test func sessionTallyAndStreaks() {
        var t = SessionTally()
        let right = Grade(isCorrect: true, errorPoints: 0, points: 100, verdict: .correct)
        let wrong = Grade(isCorrect: false, errorPoints: 3, points: 0, verdict: .incorrect)
        for g in [right, right, wrong, right, right, right] { t.record(g) }
        #expect(t.attempts == 6 && t.correct == 5)
        #expect(t.streak == 3 && t.bestStreak == 3)
        #expect(t.points == 500)
    }

    @Test func dailyStreak() {
        #expect(DailyStreak.current(days: [10, 11, 12], today: 12) == 3)
        #expect(DailyStreak.current(days: [10, 11, 12], today: 13) == 3)   // today not done yet
        #expect(DailyStreak.current(days: [10, 12], today: 12) == 1)
        #expect(DailyStreak.current(days: [], today: 5) == 0)
    }
}
