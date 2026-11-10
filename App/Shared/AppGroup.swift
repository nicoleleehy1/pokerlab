import Foundation

/// Values shared between the app and the widget extension through the App Group.
enum AppGroup {
    // TODO(Nicole): must match the App Group in both .entitlements files and your developer account.
    static let identifier = "group.com.nicolelee.PokerLab"

    static var defaults: UserDefaults { UserDefaults(suiteName: identifier) ?? .standard }

    enum Key {
        static let dailyStreak = "dailyStreak"
        static let lastDrillDay = "lastDrillDay"
        static let todayCompleted = "todayCompleted"
        static let recentAccuracy = "recentAccuracy"
    }
}

/// The daily drill is the same spot for everyone on a given calendar day: its seed is the day number.
enum DailyDrill {
    static func dayNumber(for date: Date = .now, calendar: Calendar = .current) -> Int {
        let start = calendar.startOfDay(for: date)
        return Int((start.timeIntervalSinceReferenceDate / 86_400).rounded(.down))
    }

    static func seed(for date: Date = .now) -> UInt64 { UInt64(bitPattern: Int64(dayNumber(for: date))) &* 0x9E37_79B9 }
}
