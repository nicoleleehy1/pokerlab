import SwiftUI
import SwiftData
import Charts
import PokerTraining
import PokerCourse

/// Profile tab: totals, accuracy over time, leaks, past sessions and settings.
struct ProfileView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \TrainingSession.startedAt, order: .reverse) private var sessions: [TrainingSession]
    @Query private var attempts: [DrillAttempt]
    @State private var summary = ProgressSummary()
    @Query(sort: \PlayerProfile.createdAt) private var profiles: [PlayerProfile]
    @Query private var lessons: [LessonResult]
    @Query(sort: \AnswerLogEntry.day) private var answerLog: [AnswerLogEntry]

    /// Streak and totals include course lessons as well as drills.
    private var course: CourseProgress {
        CourseProgress(records: lessons.map(\.record), extraActiveDays: Set(attempts.map { DailyDrill.dayNumber(for: $0.date) }),
                       today: DailyDrill.dayNumber())
    }
    private var spotsAnswered: Int { summary.totalAttempts + lessons.reduce(0) { $0 + $1.total } }
    private var overallAccuracy: Double? {
        let correct = Double(summary.totalAttempts) * summary.accuracy + Double(lessons.reduce(0) { $0 + $1.correct })
        return spotsAnswered == 0 ? nil : correct / Double(spotsAnswered)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                    ScreenHeader(title: "Profile")
                    HStack(spacing: 12) {
                        StatTile(title: "Day streak", value: "\(course.streak)")
                        StatTile(title: "Spots answered", value: "\(spotsAnswered)")
                        StatTile(title: "Accuracy", value: overallAccuracy.map { Theme.percent($0, digits: 0) } ?? "–")
                    }
                    MasteryCard(state: profiles.first?.adaptive ?? AdaptiveState())
                    ModelCheckCard(events: answerLog.compactMap(\.event))
                    if summary.totalAttempts == 0 {
                        Text("Finish a drill and your accuracy over time shows up here.")
                            .font(Theme.caption).foregroundStyle(Theme.muted)
                    } else {
                        accuracyChart
                        leaksChart
                        sessionList
                    }
                    RowGroup {
                        NavigationLink(value: ProfileDestination.settings) {
                            ListRow(symbol: "gearshape", title: "Settings", subtitle: "Deck colours, sync, export")
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("settings-button")
                    }
                }
                .screenPadding()
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
            .background(Theme.background)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: TrainingSession.self) { SessionDetailView(session: $0) }
            .navigationDestination(for: ProfileDestination.self) { _ in SettingsView() }
            .task(id: attempts.count) { await refresh() }
        }
    }

    private func refresh() async {
        let aggregator = ProgressAggregator(modelContainer: context.container)
        if let s = try? await aggregator.summary() { summary = s }
    }

    private var accuracyChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Accuracy, last 30 days").font(Theme.label)
            Chart(summary.days) { d in
                BarMark(x: .value("Day", d.day, unit: .day), y: .value("Accuracy", d.accuracy))
                    .foregroundStyle(Theme.ink)
                    .accessibilityLabel(d.day.formatted(date: .abbreviated, time: .omitted))
                    .accessibilityValue("\(Theme.percent(d.accuracy, digits: 0)) of \(d.attempts) spots")
            }
            .chartYScale(domain: 0...1)
            .chartYAxis { AxisMarks(format: FloatingPointFormatStyle<Double>.Percent().precision(.fractionLength(0))) }
            .frame(height: 180)
        }
        .panel()
    }

    private var leaksChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Leaks by category").font(Theme.label)
            Text("Weakest first. These come up more often in drills.").font(Theme.caption).foregroundStyle(Theme.muted)
            Chart(summary.categories) { c in
                BarMark(x: .value("Accuracy", c.accuracy), y: .value("Category", c.category.title))
                    .foregroundStyle(c.accuracy < 0.6 ? Theme.faint : Theme.ink)
                    .annotation(position: .trailing) {
                        Text(Theme.percent(c.accuracy, digits: 0)).font(.caption2.monospacedDigit()).foregroundStyle(Theme.muted)
                    }
            }
            .chartXScale(domain: 0...1)
            .chartXAxis { AxisMarks(format: FloatingPointFormatStyle<Double>.Percent().precision(.fractionLength(0))) }
            .frame(height: CGFloat(max(1, summary.categories.count)) * 36 + 30)
        }
        .panel()
    }

    private var sessionList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Sessions").font(Theme.label).padding(.bottom, 6)
            ForEach(sessions.prefix(20)) { s in
                NavigationLink(value: s) {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(s.mode.title).font(Theme.label)
                            Text(s.startedAt.formatted(date: .abbreviated, time: .shortened)).font(Theme.caption).foregroundStyle(Theme.muted)
                        }
                        Spacer()
                        Text("\(s.correctCount)/\(s.attemptCount)").font(Theme.smallNumber)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.faint)
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .panel()
    }
}

enum ProfileDestination: Hashable { case settings }

struct SessionDetailView: View {
    let session: TrainingSession
    var body: some View {
        List {
            Section {
                LabeledContent("Accuracy", value: Theme.percent(session.accuracy, digits: 0))
                LabeledContent("Points", value: "\(session.points)")
                LabeledContent("Best streak", value: "\(session.bestStreak)")
                LabeledContent("Duration", value: Duration.seconds(session.duration).formatted(.units(allowed: [.minutes, .seconds])))
            }
            Section("Answers") {
                ForEach(session.sortedAttempts) { a in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: a.isCorrect ? "checkmark.circle" : "xmark.circle")
                                .foregroundStyle(a.isCorrect ? Theme.ink : Theme.muted)
                            Text(a.spotSummary).font(.subheadline)
                        }
                        Text(detail(a)).font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .navigationTitle(session.mode.title)
    }

    private func detail(_ a: DrillAttempt) -> String {
        switch session.mode {
        case .equityQuiz: "Guessed \(Theme.percent(a.userAnswer, digits: 0)), true \(Theme.percent(a.correctAnswer))"
        case .potOdds: "\(a.userAnswer == 1 ? "Called" : "Folded") with \(Theme.percent(a.correctAnswer)) equity"
        case .rangeTrainer: "\(Theme.percent(a.userAnswer)) of combos matched"
        }
    }
}
