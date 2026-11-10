import SwiftUI
import SwiftData
import PokerCore
import PokerTraining

struct TodayView: View {
    @Environment(AppRouter.self) private var router
    @Query(sort: \DrillAttempt.date, order: .reverse) private var attempts: [DrillAttempt]
    @State private var showSettings = false

    private var todaySpot: EquityQuizSpot {
        let seed = DailyDrill.seed()
        return EquityQuiz.generate(EquityQuiz.categories[Int(seed % 4)], seed: seed)
    }
    private var dayStreak: Int {
        let days = Set(attempts.map { DailyDrill.dayNumber(for: $0.date) })
        return DailyStreak.current(days: days, today: DailyDrill.dayNumber())
    }
    private var todayCount: Int { attempts.filter { Calendar.current.isDateInToday($0.date) }.count }
    private var recentAccuracy: Double? {
        let recent = attempts.prefix(50)
        return recent.isEmpty ? nil : Double(recent.filter(\.isCorrect).count) / Double(recent.count)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    statsRow
                    dailyCard
                    quickStart
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Today")
            .toolbar {
                Button("Settings", systemImage: "gearshape") { showSettings = true }
                    .accessibilityIdentifier("settings-button")
            }
            .sheet(isPresented: $showSettings) { NavigationStack { SettingsView() } }
        }
    }

    private var statsRow: some View {
        HStack(spacing: 12) {
            StatTile(title: "Day streak", value: "\(dayStreak)", symbol: "flame.fill", tint: .orange)
            StatTile(title: "Today", value: "\(todayCount)", symbol: "checkmark.circle", tint: .green)
            StatTile(title: "Recent accuracy", value: recentAccuracy.map { Theme.percent($0, digits: 0) } ?? "–", symbol: "scope", tint: Theme.hero)
        }
    }

    private var dailyCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Daily drill", systemImage: "calendar").font(.headline)
            Text("Same spot for everyone today. How much equity does your hand have?")
                .font(.subheadline).foregroundStyle(.secondary)
            SpotCards(hero: todaySpot.hero, villainHand: todaySpot.villainHand, villainName: todaySpot.villain?.name, board: todaySpot.board)
            Button { router.open(.dailyDrill) } label: { Text("Answer today's spot").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .accessibilityIdentifier("daily-drill-button")
        }
        .panel()
    }

    private var quickStart: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Quick start").font(.headline).padding(.bottom, 6)
            ForEach(DrillKind.allCases) { kind in
                Button { router.open(.drill(kind)) } label: {
                    DrillRow(kind: kind).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if kind != DrillKind.allCases.last { Divider() }
            }
        }
        .panel()
    }
}

struct StatTile: View {
    let title: String
    let value: String
    let symbol: String
    let tint: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(tint).accessibilityHidden(true)
            Text(value).font(Theme.mediumNumber).contentTransition(.numericText()).minimumScaleFactor(0.6).lineLimit(1)
            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }
}
