import Foundation
import SwiftData
import PokerTraining

/// Sendable summary for the Progress screen.
struct ProgressSummary: Sendable, Equatable {
    struct Day: Sendable, Equatable, Identifiable {
        var id: Date { day }
        let day: Date
        let attempts: Int
        let accuracy: Double
    }
    struct Category: Sendable, Equatable, Identifiable {
        var id: String { category.rawValue }
        let category: SkillCategory
        let attempts: Int
        let accuracy: Double
        let averageError: Double
    }
    var days: [Day] = []
    var categories: [Category] = []
    var totalAttempts = 0
    var accuracy = 0.0
    var dailyStreak = 0
    var bestSessionStreak = 0
}

/// Aggregates attempts off the main thread.
@ModelActor
actor ProgressAggregator {
    func summary(days lookback: Int = 30, now: Date = .now) throws -> ProgressSummary {
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: -lookback, to: calendar.startOfDay(for: now))!
        let all = try modelContext.fetch(FetchDescriptor<DrillAttempt>(sortBy: [SortDescriptor(\.date)]))
        let recent = all.filter { $0.date >= start }
        var summary = ProgressSummary()
        summary.totalAttempts = all.count
        summary.accuracy = all.isEmpty ? 0 : Double(all.filter(\.isCorrect).count) / Double(all.count)

        let byDay = Dictionary(grouping: recent) { calendar.startOfDay(for: $0.date) }
        summary.days = byDay.keys.sorted().map { day in
            let xs = byDay[day]!
            return .init(day: day, attempts: xs.count, accuracy: Double(xs.filter(\.isCorrect).count) / Double(xs.count))
        }
        let byCategory = Dictionary(grouping: all) { $0.category }
        summary.categories = byCategory.map { cat, xs in
            .init(category: cat, attempts: xs.count,
                  accuracy: Double(xs.filter(\.isCorrect).count) / Double(xs.count),
                  averageError: xs.map(\.error).reduce(0, +) / Double(xs.count))
        }.sorted { $0.accuracy < $1.accuracy }
        let dayNumbers = Set(all.map { DailyDrill.dayNumber(for: $0.date, calendar: calendar) })
        summary.dailyStreak = DailyStreak.current(days: dayNumbers, today: DailyDrill.dayNumber(for: now, calendar: calendar))
        let sessions = try modelContext.fetch(FetchDescriptor<TrainingSession>())
        summary.bestSessionStreak = sessions.map(\.bestStreak).max() ?? 0
        return summary
    }
}
