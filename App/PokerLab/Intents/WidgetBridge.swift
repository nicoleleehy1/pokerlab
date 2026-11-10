import Foundation
import SwiftData
import WidgetKit
import PokerTraining

/// Writes the numbers the widget shows into the App Group and asks WidgetKit to refresh.
@MainActor
enum WidgetBridge {
    static func recordDrillCompleted(context: ModelContext, isDaily: Bool) {
        let attempts = (try? context.fetch(FetchDescriptor<DrillAttempt>(sortBy: [SortDescriptor(\.date, order: .reverse)]))) ?? []
        let days = Set(attempts.map { DailyDrill.dayNumber(for: $0.date) })
        let today = DailyDrill.dayNumber()
        let recent = attempts.prefix(50)
        let d = AppGroup.defaults
        d.set(DailyStreak.current(days: days, today: today), forKey: AppGroup.Key.dailyStreak)
        d.set(today, forKey: AppGroup.Key.lastDrillDay)
        if isDaily { d.set(today, forKey: AppGroup.Key.todayCompleted) }
        d.set(recent.isEmpty ? 0 : Double(recent.filter(\.isCorrect).count) / Double(recent.count), forKey: AppGroup.Key.recentAccuracy)
        WidgetCenter.shared.reloadAllTimelines()
    }
}
