import Foundation
import SwiftData
import PokerCore
import PokerTraining
import PokerCourse

// CloudKit-compatible SwiftData schema:
//  - every stored property has a default value or is optional,
//  - every relationship is optional (CloudKit has no required relationships),
//  - no @Attribute(.unique) (CloudKit cannot enforce uniqueness),
//  - hands and boards are stored as compact Int64 card masks rather than child objects, which
//    keeps sync payloads small (CloudKit has no unsigned 64-bit type, hence Int64).

@Model
final class TrainingSession {
    var id: UUID = UUID()
    var startedAt: Date = Date.now
    var endedAt: Date?
    var modeRaw: String = DrillKind.equityQuiz.rawValue
    var points: Int = 0
    var attemptCount: Int = 0
    var correctCount: Int = 0
    var bestStreak: Int = 0
    @Relationship(deleteRule: .cascade, inverse: \DrillAttempt.session)
    var attempts: [DrillAttempt]? = []

    init(mode: DrillKind, startedAt: Date = .now) {
        self.modeRaw = mode.rawValue
        self.startedAt = startedAt
    }

    var mode: DrillKind { DrillKind(rawValue: modeRaw) ?? .equityQuiz }
    var accuracy: Double { attemptCount == 0 ? 0 : Double(correctCount) / Double(attemptCount) }
    var duration: TimeInterval { (endedAt ?? .now).timeIntervalSince(startedAt) }
    var sortedAttempts: [DrillAttempt] { (attempts ?? []).sorted { $0.date < $1.date } }
}

@Model
final class DrillAttempt {
    var id: UUID = UUID()
    var date: Date = Date.now
    var categoryRaw: String = SkillCategory.preflopMatchups.rawValue
    /// Human-readable spot, e.g. "AhKh vs QsQd on Qd7h2h".
    var spotSummary: String = ""
    var heroMask: Int64 = 0
    var villainMask: Int64 = 0
    var boardMask: Int64 = 0
    var villainRange: String = ""
    /// Equity Quiz: guessed equity. Pot Odds: 1 = call, 0 = fold. Range Trainer: accuracy.
    var userAnswer: Double = 0
    /// Equity Quiz / Pot Odds: true equity. Range Trainer: 1.
    var correctAnswer: Double = 0
    var error: Double = 0
    var isCorrect: Bool = false
    var points: Int = 0
    var timeTaken: Double = 0
    var session: TrainingSession?

    init() {}

    var category: SkillCategory { SkillCategory(rawValue: categoryRaw) ?? .preflopMatchups }
    var hero: CardSet { CardSet(rawValue: UInt64(bitPattern: heroMask)) }
    var board: CardSet { CardSet(rawValue: UInt64(bitPattern: boardMask)) }
}

@Model
final class SavedSpot {
    var id: UUID = UUID()
    var name: String = ""
    var createdAt: Date = Date.now
    var heroNotation: String = ""
    var villainNotation: String = ""
    var boardMask: Int64 = 0

    init(name: String, hero: String, villain: String, board: CardSet) {
        self.name = name; heroNotation = hero; villainNotation = villain
        boardMask = Int64(bitPattern: board.rawValue)
    }

    var board: CardSet { CardSet(rawValue: UInt64(bitPattern: boardMask)) }
}

@Model
final class PlayerProfile {
    var id: UUID = UUID()
    var createdAt: Date = Date.now
    var dailyGoal: Int = 10
    var bestStreak: Int = 0
    /// Encoded `SkillScheduler` (spaced-repetition state).
    var schedulerData: Data?
    /// Encoded `AdaptiveState` (FSRS per template, Elo per concept) for the course.
    var adaptiveData: Data?

    init() {}

    var scheduler: SkillScheduler {
        get { schedulerData.flatMap { try? JSONDecoder().decode(SkillScheduler.self, from: $0) } ?? SkillScheduler() }
        set { schedulerData = try? JSONEncoder().encode(newValue) }
    }

    var adaptive: AdaptiveState {
        get { adaptiveData.flatMap { try? JSONDecoder().decode(AdaptiveState.self, from: $0) } ?? AdaptiveState() }
        set { adaptiveData = try? JSONEncoder().encode(newValue) }
    }

    /// Adaptive-layer clock: fractional days.
    static func adaptiveNow(_ date: Date = .now) -> Double { date.timeIntervalSinceReferenceDate / 86_400 }

    /// Feeds a finished lesson's answers to FSRS and Elo.
    func recordAdaptive(_ outcome: LessonOutcome) {
        var state = adaptive
        let now = Self.adaptiveNow()
        for (i, id) in outcome.templateIDs.enumerated() {
            guard let id, let t = TemplateID(rawValue: id) else { continue }
            state.record(t, lossFraction: outcome.lossFractions[i], seconds: outcome.durations[i], at: now)
        }
        adaptive = state
    }

    /// Profiles can be duplicated across devices before the first sync (no unique constraints in
    /// CloudKit), so always use the oldest one.
    @MainActor static func current(in context: ModelContext) -> PlayerProfile {
        var descriptor = FetchDescriptor<PlayerProfile>(sortBy: [SortDescriptor(\.createdAt)])
        descriptor.fetchLimit = 1
        if let existing = try? context.fetch(descriptor).first { return existing }
        let profile = PlayerProfile()
        context.insert(profile)
        return profile
    }
}

/// A finished course lesson. XP, streaks and the lesson path are derived from these.
@Model
final class LessonResult {
    var id: UUID = UUID()
    var date: Date = Date.now
    var lessonID: String = ""
    var correct: Int = 0
    var total: Int = 0
    var xp: Int = 0
    /// Mean EV loss per question as a fraction of the pot (estimates: points / 100).
    var meanLossFraction: Double = 0

    init(lessonID: String, correct: Int, total: Int, meanLossFraction: Double, date: Date = .now) {
        self.lessonID = lessonID; self.correct = correct; self.total = total
        self.meanLossFraction = meanLossFraction; self.date = date
        xp = XP.forLesson(correct: correct, total: total)
    }

    var record: LessonRecord {
        LessonRecord(lessonID: lessonID, day: DailyDrill.dayNumber(for: date), correct: correct, total: total)
    }
}

enum PokerLabSchema {
    static let models: [any PersistentModel.Type] = [TrainingSession.self, DrillAttempt.self, SavedSpot.self, PlayerProfile.self,
                                                     LessonResult.self]
}
