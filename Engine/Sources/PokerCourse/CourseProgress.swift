/// XP, streaks, daily goal and lesson-path state. Pure value logic: the app persists the
/// underlying lesson records with SwiftData and feeds them in.
public enum XP {
    public static let perCorrectAnswer = 10
    public static let lessonComplete = 20
    public static let perfectBonus = 20

    /// XP for one finished lesson.
    public static func forLesson(correct: Int, total: Int) -> Int {
        correct * perCorrectAnswer + lessonComplete + (correct == total && total > 0 ? perfectBonus : 0)
    }
}

/// One finished lesson, as stored.
public struct LessonRecord: Hashable, Sendable, Codable {
    public let lessonID: String
    /// Calendar day number (days since a reference date; the app supplies it).
    public let day: Int
    public let correct: Int
    public let total: Int
    public let xp: Int

    public init(lessonID: String, day: Int, correct: Int, total: Int) {
        self.lessonID = lessonID; self.day = day; self.correct = correct; self.total = total
        xp = XP.forLesson(correct: correct, total: total)
    }

    public var accuracy: Double { total == 0 ? 0 : Double(correct) / Double(total) }
}

public struct CourseProgress: Hashable, Sendable {
    public enum Status: String, Hashable, Sendable { case done, current, locked }

    public struct PathItem: Hashable, Sendable, Identifiable {
        public let lesson: Lesson
        public let unit: Int
        public let status: Status
        /// Best accuracy so far (nil if never finished).
        public let bestAccuracy: Double?
        public var id: String { lesson.id }
    }

    public let records: [LessonRecord]
    /// Days with any practice (lessons or drills).
    public let activeDays: Set<Int>
    public let today: Int
    public let dailyGoalXP: Int

    public init(records: [LessonRecord], extraActiveDays: Set<Int> = [], today: Int, dailyGoalXP: Int = 50) {
        self.records = records
        activeDays = extraActiveDays.union(records.map(\.day))
        self.today = today
        self.dailyGoalXP = dailyGoalXP
    }

    public var totalXP: Int { records.reduce(0) { $0 + $1.xp } }
    public var xpToday: Int { records.filter { $0.day == today }.reduce(0) { $0 + $1.xp } }
    public var dailyGoalMet: Bool { xpToday >= dailyGoalXP }

    /// Consecutive active days ending today, or yesterday if today has no practice yet (the
    /// streak isn't lost until a full day is missed).
    public var streak: Int {
        var d = activeDays.contains(today) ? today : today - 1
        var n = 0
        while activeDays.contains(d) { n += 1; d -= 1 }
        return n
    }

    public var completedLessons: Set<String> { Set(records.map(\.lessonID)) }

    /// Every lesson in course order. The first unfinished lesson in an available unit is current;
    /// later ones (and every lesson in an unavailable unit) are locked.
    public func path(units: [CourseUnit] = Curriculum.units) -> [PathItem] {
        let done = completedLessons
        var foundCurrent = false
        var items: [PathItem] = []
        for unit in units {
            for lesson in unit.lessons {
                let best = records.filter { $0.lessonID == lesson.id }.map(\.accuracy).max()
                let status: Status
                if done.contains(lesson.id) { status = .done }
                else if unit.isAvailable && !foundCurrent { status = .current; foundCurrent = true }
                else { status = .locked }
                items.append(PathItem(lesson: lesson, unit: unit.number, status: status, bestAccuracy: best))
            }
        }
        return items
    }

    /// The unit holding the current lesson (or the last unit when everything available is done).
    public func currentUnit(units: [CourseUnit] = Curriculum.units) -> CourseUnit {
        let path = path(units: units)
        if let current = path.first(where: { $0.status == .current }) {
            return units.first { $0.number == current.unit }!
        }
        return units.last { $0.isAvailable } ?? units[0]
    }
}
