import SwiftUI
import SwiftData
import PokerCore
import PokerTraining

/// One drill session as a small state machine:
/// loading -> question -> (submit) -> answered -> (next) -> question ... -> finished.
/// Every answer is saved as a DrillAttempt; the scheduler picks the next category.
@MainActor @Observable
final class DrillSessionModel {
    enum Phase: Equatable { case loading, question, answered, finished }
    enum Spot: Equatable {
        case quiz(EquityQuizSpot)
        case potOdds(PotOddsSpot)
        case range(RangeTrainerSpot)
    }

    let kind: DrillKind
    let isDaily: Bool
    let length: Int
    private(set) var phase: Phase = .loading
    private(set) var spot: Spot?
    private(set) var grade: Grade?
    private(set) var truth: Double?
    private(set) var comparison: RangeComparison?
    private(set) var tally = SessionTally()
    private(set) var feedbackTrigger = 0
    var guess = 0.5
    var painted: Set<HandClass> = []

    private var context: ModelContext?
    private var session: TrainingSession?
    private var profile: PlayerProfile?
    private var scheduler = SkillScheduler()
    private var truthTask: Task<Double?, Never>?
    private var questionStart = Date.now
    private var questionIndex = 0

    init(kind: DrillKind, isDaily: Bool = false, length: Int = 10) {
        self.kind = kind
        self.isDaily = isDaily
        self.length = isDaily ? 1 : length
    }

    var progressText: String { "\(min(tally.attempts + (phase == .answered ? 0 : 1), length)) of \(length)" }

    func start(context: ModelContext) {
        guard self.context == nil else { return }
        self.context = context
        let profile = PlayerProfile.current(in: context)
        self.profile = profile
        scheduler = profile.scheduler
        let session = TrainingSession(mode: kind)
        context.insert(session)
        self.session = session
        DrillLiveActivity.start(drillName: isDaily ? "Daily drill" : kind.title)
        next()
    }

    func next() {
        guard tally.attempts < length else { finish(); return }
        phase = .loading
        grade = nil; truth = nil; comparison = nil
        guess = 0.5; painted = []
        let seed = isDaily ? DailyDrill.seed() : UInt64.random(in: 0...UInt64.max)
        let category = isDaily ? SkillCategory.preflopMatchups : scheduler.next(in: kind, seed: seed)
        questionIndex += 1
        switch kind {
        case .equityQuiz:
            let s = isDaily ? EquityQuiz.generate(EquityQuiz.categories[Int(seed % 4)], seed: seed) : EquityQuiz.generate(category, seed: seed)
            spot = .quiz(s)
            truthTask = Task.detached(priority: .userInitiated) { try? await s.solve() }
        case .potOdds:
            let s = PotOddsDrill.generate(category, seed: seed)
            spot = .potOdds(s)
            truthTask = Task.detached(priority: .userInitiated) { try? await s.solve() }
        case .rangeTrainer:
            let s = RangeTrainer.generate(category, seed: seed)
            spot = .range(s)
            truthTask = nil
            // Warm the chart cache while the player paints.
            Task.detached(priority: .utility) { _ = await PushFoldCharts.shared.solution(stack: s.stack) }
        }
        questionStart = .now
        phase = .question
    }

    func submitGuess() async {
        guard case .quiz(let s) = spot, phase == .question, let t = await truthTask?.value else { return }
        let g = EquityQuiz.grade(guess: guess, truth: t)
        record(g, truth: t, answer: guess, category: s.category, summary: Self.summary(s), hero: s.hero.mask,
               villain: s.villainHand?.mask ?? 0, villainRange: s.villain?.name ?? "", board: s.board.rawValue)
    }

    func submitDecision(call: Bool) async {
        guard case .potOdds(let s) = spot, phase == .question, let t = await truthTask?.value else { return }
        let g = PotOddsDrill.grade(called: call, spot: s, equity: t)
        record(g, truth: t, answer: call ? 1 : 0, category: s.category,
               summary: "\(s.hero) vs \(s.villain.name)\(s.board.isEmpty ? "" : " on \(s.board)"), pot \(s.pot.formatted()) bb, bet \(s.bet.formatted()) bb",
               hero: s.hero.mask, villain: 0, villainRange: s.villain.name, board: s.board.rawValue)
    }

    func submitRange() async {
        guard case .range(let s) = spot, phase == .question else { return }
        let reference = await RangeTrainer.reference(for: s, charts: .shared)
        let c = RangeTrainer.compare(painted: painted, reference: reference)
        comparison = c
        record(RangeTrainer.grade(c), truth: 1, answer: c.accuracy, category: s.category, summary: s.prompt,
               hero: 0, villain: 0, villainRange: "", board: 0)
    }

    private func record(_ g: Grade, truth t: Double, answer: Double, category: SkillCategory, summary: String,
                        hero: UInt64, villain: UInt64, villainRange: String, board: UInt64) {
        grade = g
        truth = t
        tally.record(g)
        scheduler.record(category, correct: g.isCorrect)
        feedbackTrigger += 1
        if let context, let session {
            let a = DrillAttempt()
            a.date = .now
            a.categoryRaw = category.rawValue
            a.spotSummary = summary
            a.heroMask = Int64(bitPattern: hero); a.villainMask = Int64(bitPattern: villain); a.boardMask = Int64(bitPattern: board)
            a.villainRange = villainRange
            a.userAnswer = answer; a.correctAnswer = t
            a.error = g.errorPoints; a.isCorrect = g.isCorrect; a.points = g.points
            a.timeTaken = Date.now.timeIntervalSince(questionStart)
            a.session = session
            context.insert(a)
            session.attemptCount = tally.attempts
            session.correctCount = tally.correct
            session.points = tally.points
            session.bestStreak = tally.bestStreak
            profile?.scheduler = scheduler
            if let profile { profile.bestStreak = max(profile.bestStreak, tally.bestStreak) }
            try? context.save()
            WidgetBridge.recordDrillCompleted(context: context, isDaily: isDaily)
        }
        DrillLiveActivity.update(answered: tally.attempts, correct: tally.correct, streak: tally.streak, points: tally.points)
        phase = .answered
    }

    func finish() {
        guard phase != .finished else { return }
        session?.endedAt = .now
        if let session, session.attemptCount == 0 { context?.delete(session) }
        try? context?.save()
        DrillLiveActivity.end(answered: tally.attempts, correct: tally.correct, streak: tally.streak, points: tally.points)
        phase = .finished
    }

    static func summary(_ s: EquityQuizSpot) -> String {
        "\(s.hero) vs \(s.villainDescription)\(s.board.isEmpty ? " preflop" : " on \(s.board)")"
    }
}
