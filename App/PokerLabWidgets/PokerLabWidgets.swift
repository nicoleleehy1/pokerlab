import WidgetKit
import SwiftUI
import PokerCore
import PokerTraining

@main
struct PokerLabWidgets: WidgetBundle {
    var body: some Widget {
        DailyDrillWidget()
        #if canImport(ActivityKit)
        DrillLiveActivityWidget()
        #endif
    }
}

struct DailyDrillEntry: TimelineEntry {
    let date: Date
    let spot: EquityQuizSpot
    let streak: Int
    let completedToday: Bool
    let recentAccuracy: Double
}

struct DailyDrillProvider: TimelineProvider {
    func placeholder(in context: Context) -> DailyDrillEntry { entry(for: .now) }
    func getSnapshot(in context: Context, completion: @escaping (DailyDrillEntry) -> Void) { completion(entry(for: .now)) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<DailyDrillEntry>) -> Void) {
        // New spot at midnight.
        let tomorrow = Calendar.current.startOfDay(for: .now.addingTimeInterval(86_400))
        completion(Timeline(entries: [entry(for: .now)], policy: .after(tomorrow)))
    }

    func entry(for date: Date) -> DailyDrillEntry {
        let seed = DailyDrill.seed(for: date)
        let d = AppGroup.defaults
        let today = DailyDrill.dayNumber(for: date)
        let last = d.integer(forKey: AppGroup.Key.lastDrillDay)
        let streak = (last == today || last == today - 1) ? d.integer(forKey: AppGroup.Key.dailyStreak) : 0
        return DailyDrillEntry(date: date,
                               spot: EquityQuiz.generate(EquityQuiz.categories[Int(seed % 4)], seed: seed),
                               streak: streak,
                               completedToday: d.integer(forKey: AppGroup.Key.todayCompleted) == today,
                               recentAccuracy: d.double(forKey: AppGroup.Key.recentAccuracy))
    }
}

struct DailyDrillWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "DailyDrill", provider: DailyDrillProvider()) { entry in
            DailyDrillWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(URL(string: "pokerlab://daily"))
        }
        .configurationDisplayName("Daily Drill")
        .description("Today's equity spot and your streak.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

struct DailyDrillWidgetView: View {
    let entry: DailyDrillEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryRectangular:
            VStack(alignment: .leading) {
                Label("\(entry.streak) day streak", systemImage: "flame.fill").font(.headline)
                Text(entry.completedToday ? "Daily drill done" : "\(String(describing: entry.spot.hero)) vs \(entry.spot.villainDescription)")
                    .font(.caption)
            }
        case .systemMedium:
            HStack(spacing: 16) {
                streakColumn
                VStack(alignment: .leading, spacing: 6) {
                    Text("Today's spot").font(.caption).foregroundStyle(.secondary)
                    Text(spotText).font(.headline).minimumScaleFactor(0.7)
                    Text(entry.completedToday ? "Done. Come back tomorrow." : "What's your equity?")
                        .font(.subheadline).foregroundStyle(entry.completedToday ? Color.green : Color.accentColor)
                }
                Spacer(minLength: 0)
            }
        default:
            VStack(alignment: .leading, spacing: 6) {
                streakColumn
                Spacer(minLength: 0)
                Text(entry.completedToday ? "Done today" : spotText).font(.caption.weight(.medium)).lineLimit(2)
            }
        }
    }

    private var spotText: String {
        "\(String(describing: entry.spot.hero)) vs \(entry.spot.villainDescription)" + (entry.spot.board.isEmpty ? "" : " on \(entry.spot.board)")
    }

    private var streakColumn: some View {
        VStack(alignment: .leading, spacing: 2) {
            Image(systemName: "flame.fill").foregroundStyle(.orange)
            Text("\(entry.streak)").font(.system(.title, design: .rounded, weight: .semibold).monospacedDigit())
            Text("day streak").font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
