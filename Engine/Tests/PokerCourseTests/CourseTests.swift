import Testing
import PokerCore
@testable import PokerCourse

@Suite("EV-loss grading")
struct GradingTests {
    func question(_ evs: [Double], pot: Double) -> Question {
        Question(id: "t", concept: .callOrFold, kind: .decision, prompt: "",
                 options: evs.enumerated().map { .init("o\($0.offset)", ev: $0.element) }, pot: pot, explanation: "")
    }

    @Test func thresholdsArePercentOfPot() {
        let q = question([0, -0.05, -0.4, -1.2, -3], pot: 10)
        #expect(q.grade(0).verdict == .best)
        #expect(q.grade(1).verdict == .correct)      // 0.5% of pot: equal EV
        #expect(q.grade(2).verdict == .inaccuracy)   // 4%
        #expect(q.grade(3).verdict == .mistake)      // 12%
        #expect(q.grade(4).verdict == .blunder)      // 30%
        #expect(q.correctOptions == [0, 1])
    }

    @Test func nearlyEqualActionsAreBothCorrect() {
        let q = question([1.00, 0.95], pot: 20)      // 0.25% of the pot apart
        #expect(q.correctOptions == [0, 1])
        #expect(q.grade(1).isCorrect)
    }

    @Test func boundaryIsInclusive() {
        let q = question([0, -0.1], pot: 10)         // exactly 1%
        #expect(q.grade(1).verdict == .correct)
    }
}

@Suite("Question generators")
struct GeneratorTests {
    static let available = TemplateID.allCases.filter { !$0.needsRiverSolver }

    @Test("Every template produces gradable questions", arguments: available)
    func templateIsWellFormed(_ t: TemplateID) async throws {
        for seed in UInt64(1)...12 {
            let q = try await t.generate(seed: seed)
            #expect(q.options.count >= 2)
            #expect(Set(q.options.map(\.label)).count == q.options.count, "\(t) duplicate labels \(q.options.map(\.label))")
            #expect(!q.correctOptions.isEmpty)
            #expect(q.options.allSatisfy { $0.ev.isFinite })
            #expect(!q.explanation.isEmpty && !q.prompt.isEmpty)
            #expect(q.concept == t.concept)
            let cards = q.hero + q.villain + q.board
            #expect(Set(cards).count == cards.count, "duplicate cards in \(t) seed \(seed)")
        }
    }

    @Test func generatorsAreDeterministic() async throws {
        for t in [TemplateID.requiredEquity, .equityVsHand, .pushFold, .icmCall, .bluffCatch] {
            let a = try await t.generate(seed: 42), b = try await t.generate(seed: 42)
            #expect(a == b)
        }
    }

    @Test func riverTemplatesAreLockedWithoutTheSolver() async {
        guard RiverQuestions.generator == nil else { return }
        await #expect(throws: CourseError.requiresRiverSolver) { try await TemplateID.riverBet.generate(seed: 1) }
    }

    @Test func requiredEquityMatchesFormula() async throws {
        for seed in UInt64(1)...30 {
            let q = try await TemplateID.requiredEquity.generate(seed: seed)
            let best = q.options[q.options.indices.max { q.options[$0].ev < q.options[$1].ev }!]
            #expect(best.ev >= -0.5 - 1e-9, "best option should be the rounded truth, got \(best) in \(q.options)")
        }
    }

    /// Pot-sized bet: MDF 50%, bluff share 33%, required equity 33%.
    @Test func toyGameFormulas() {
        let s = 1.0
        #expect(abs(1 / (1 + s) - 0.5) < 1e-12)
        #expect(abs(s / (2 * s + 1) - 1.0 / 3) < 1e-12)
        let half = 0.5
        #expect(abs(half / (2 * half + 1) - 0.25) < 1e-12)
    }

    @Test func bluffCatchEVIsZeroAtIndifference() {
        let pot = 10.0, bet = 10.0
        let b = bet / (pot + 2 * bet)
        #expect(abs(b * (pot + bet) - (1 - b) * bet) < 1e-12)
    }

    /// Push/fold EVs come from the solved Nash strategy, so the best action should agree with
    /// the solver's (near-)pure choices.
    @Test func pushFoldBestActionMatchesNash() async throws {
        var checked = 0
        for seed in UInt64(1)...40 {
            let q = try await TemplateID.pushFold.generate(seed: seed)
            let stack = Double(q.facts[0].value.split(separator: " ")[0])!
            let sol = await PushFoldCache.shared.solution(stack: stack)
            let hc = HoleCards(q.hero[0], q.hero[1]).handClass
            let freq = sol.push[hc.index]
            guard freq < 0.05 || freq > 0.95 else { continue }
            #expect(q.correctOptions.contains(freq > 0.5 ? 1 : 0), "\(hc) at \(stack) bb: Nash \(freq)")
            checked += 1
        }
        #expect(checked > 20)
    }

    @Test func lessonsHaveTenQuestions() async throws {
        let lesson = Curriculum.lesson("u5-l1")!
        let qs = try await Curriculum.questions(for: lesson, seed: 7)
        #expect(qs.count == 10)
        #expect(Set(qs.map(\.id)).count == 10)
    }
}

@Suite("ICM")
struct ICMTests {
    @Test func equalStacksSplitEvenly() {
        let e = ICM.equities(stacks: [1000, 1000, 1000], payouts: [50, 30, 20])
        for x in e { #expect(abs(x - 100.0 / 3) < 1e-9) }
    }

    @Test func equitiesSumToPrizePool() {
        let e = ICM.equities(stacks: [5000, 3000, 1500, 500], payouts: [50, 30, 20])
        #expect(abs(e.reduce(0, +) - 100) < 1e-9)
    }

    /// Chips are worth less as you gain them: the leader's prize share is below its chip share.
    @Test func chipLeaderIsWorthLessThanChipShare() {
        let e = ICM.equities(stacks: [6000, 2000, 2000], payouts: [50, 30, 20])
        #expect(e[0] < 60 && e[0] > 20)
        #expect(e[1] > 20)
    }

    @Test func headsUpIsProportional() {
        let e = ICM.equities(stacks: [3000, 1000], payouts: [70, 30])
        #expect(abs(e[0] - (30 + 40 * 0.75)) < 1e-9)
    }

    @Test func bustedPlayerTakesLastPrize() {
        let e = ICM.equities(stacks: [0, 2000, 1000], payouts: [50, 30, 20])
        #expect(abs(e[0] - 20) < 1e-9)
        #expect(abs(e.reduce(0, +) - 100) < 1e-9)
    }
}

@Suite("XP, streaks and the lesson path")
struct ProgressTests {
    @Test func xpRules() {
        #expect(XP.forLesson(correct: 7, total: 10) == 90)
        #expect(XP.forLesson(correct: 10, total: 10) == 140)
    }

    @Test func streakSurvivesUntilADayIsMissed() {
        let r = [LessonRecord(lessonID: "u1-l1", day: 98, correct: 5, total: 10),
                 LessonRecord(lessonID: "u1-l2", day: 99, correct: 5, total: 10)]
        #expect(CourseProgress(records: r, today: 100).streak == 2)   // today not practised yet
        #expect(CourseProgress(records: r, today: 99).streak == 2)
        #expect(CourseProgress(records: r, today: 101).streak == 0)
        #expect(CourseProgress(records: r, extraActiveDays: [100], today: 100).streak == 3)
    }

    @Test func dailyGoal() {
        let r = [LessonRecord(lessonID: "u1-l1", day: 5, correct: 3, total: 10)]   // 50 XP
        let p = CourseProgress(records: r, today: 5, dailyGoalXP: 50)
        #expect(p.xpToday == 50 && p.dailyGoalMet)
        #expect(!CourseProgress(records: r, today: 6).dailyGoalMet)
    }

    @Test func pathHasOneCurrentLesson() {
        let fresh = CourseProgress(records: [], today: 1).path()
        #expect(fresh.first?.status == .current)
        #expect(fresh.filter { $0.status == .current }.count == 1)
        let r = [LessonRecord(lessonID: "u1-l1", day: 1, correct: 9, total: 10)]
        let p = CourseProgress(records: r, today: 1)
        #expect(p.path()[0].status == .done)
        #expect(p.path()[1].status == .current)
        #expect(p.path()[0].bestAccuracy == 0.9)
        #expect(p.currentUnit().number == 1)
    }

    @Test func unavailableUnitsAreSkipped() {
        let early = Curriculum.units.prefix(6).flatMap(\.lessons).map {
            LessonRecord(lessonID: $0.id, day: 1, correct: 10, total: 10)
        }
        let p = CourseProgress(records: early, today: 1)
        let current = p.path().first { $0.status == .current }!
        if RiverCapability.isAvailable { #expect(current.unit == 7) } else { #expect(current.unit == 10) }
    }

    @Test func curriculumHasTenUnits() {
        #expect(Curriculum.units.map(\.number) == Array(1...10))
        #expect(Set(Curriculum.lessons.map(\.id)).count == Curriculum.lessons.count)
    }
}
