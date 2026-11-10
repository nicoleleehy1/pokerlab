import PokerCore

/// Leitner-box spaced repetition over skill categories. Correct answers promote a category to
/// a higher box (reviewed less often); misses send it back to box 0. Pure value type so the app
/// can persist it and tests can drive it deterministically.
public struct SkillScheduler: Hashable, Sendable, Codable {
    public static let boxIntervals = [1, 2, 4, 8, 16]   // drills between reviews

    public struct Entry: Hashable, Sendable, Codable {
        public var box = 0
        public var dueAt = 0
        public var attempts = 0
        public var correct = 0
        public var accuracy: Double { attempts == 0 ? 0 : Double(correct) / Double(attempts) }
    }

    public private(set) var entries: [SkillCategory: Entry]
    public private(set) var clock = 0

    public init(categories: [SkillCategory] = SkillCategory.allCases) {
        entries = Dictionary(uniqueKeysWithValues: categories.map { ($0, Entry()) })
    }

    /// Next category: the most overdue among due ones, preferring lower boxes; ties broken by `seed`.
    public func next(in kind: DrillKind? = nil, seed: UInt64 = 0) -> SkillCategory {
        let pool = entries.filter { kind == nil || $0.key.kind == kind }
        let due = pool.filter { $0.value.dueAt <= clock }
        let candidates = due.isEmpty ? pool : due
        let sorted = candidates.sorted {
            ($0.value.box, $0.value.dueAt, $0.key.rawValue) < ($1.value.box, $1.value.dueAt, $1.key.rawValue)
        }
        let best = sorted.first!.value
        let ties = sorted.filter { $0.value.box == best.box && $0.value.dueAt == best.dueAt }
        var rng = Xoshiro256(seed: seed &+ UInt64(clock))
        return ties[Int(rng.next(below: UInt64(ties.count)))].key
    }

    public mutating func record(_ category: SkillCategory, correct: Bool) {
        clock += 1
        var e = entries[category] ?? Entry()
        e.attempts += 1
        if correct { e.correct += 1; e.box = min(e.box + 1, Self.boxIntervals.count - 1) } else { e.box = 0 }
        e.dueAt = clock + Self.boxIntervals[e.box]
        entries[category] = e
    }

    /// Categories ordered weakest first (lowest accuracy among attempted).
    public var leaks: [(SkillCategory, Double)] {
        entries.filter { $0.value.attempts > 0 }.map { ($0.key, $0.value.accuracy) }.sorted { $0.1 < $1.1 }
    }
}

/// Running totals for one drill session (mirrors what the app persists).
public struct SessionTally: Hashable, Sendable, Codable {
    public private(set) var attempts = 0
    public private(set) var correct = 0
    public private(set) var points = 0
    public private(set) var streak = 0
    public private(set) var bestStreak = 0

    public init() {}

    public var accuracy: Double { attempts == 0 ? 0 : Double(correct) / Double(attempts) }

    public mutating func record(_ grade: Grade) {
        attempts += 1
        points += grade.points
        if grade.isCorrect { correct += 1; streak += 1; bestStreak = max(bestStreak, streak) } else { streak = 0 }
    }
}

/// Daily streak from the dates on which at least one drill was completed (calendar days as
/// integer day numbers, e.g. days since a reference date; the app supplies them).
public enum DailyStreak {
    public static func current(days: Set<Int>, today: Int) -> Int {
        var d = days.contains(today) ? today : today - 1
        var n = 0
        while days.contains(d) { n += 1; d -= 1 }
        return n
    }
}
