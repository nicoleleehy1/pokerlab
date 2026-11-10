import SwiftUI
import SwiftData
import Charts
import PokerTraining

struct ProgressScreen: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \TrainingSession.startedAt, order: .reverse) private var sessions: [TrainingSession]
    @Query private var attempts: [DrillAttempt]
    @State private var summary = ProgressSummary()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if summary.totalAttempts == 0 {
                        ContentUnavailableView("No drills yet", systemImage: "chart.line.uptrend.xyaxis",
                                               description: Text("Finish a drill and your accuracy shows up here."))
                    } else {
                        HStack(spacing: 12) {
                            StatTile(title: "Spots answered", value: "\(summary.totalAttempts)", symbol: "square.stack", tint: Theme.hero)
                            StatTile(title: "Accuracy", value: Theme.percent(summary.accuracy, digits: 0), symbol: "scope", tint: .green)
                            StatTile(title: "Day streak", value: "\(summary.dailyStreak)", symbol: "flame.fill", tint: .orange)
                        }
                        accuracyChart
                        leaksChart
                        sessionList
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Progress")
            .navigationDestination(for: TrainingSession.self) { SessionDetailView(session: $0) }
            .task(id: attempts.count) { await refresh() }
        }
    }

    private func refresh() async {
        let aggregator = ProgressAggregator(modelContainer: context.container)
        if let s = try? await aggregator.summary() { summary = s }
    }

    private var accuracyChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Accuracy, last 30 days").font(.headline)
            Chart(summary.days) { d in
                BarMark(x: .value("Day", d.day, unit: .day), y: .value("Accuracy", d.accuracy))
                    .foregroundStyle(Theme.hero.gradient)
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
            Text("Leaks by category").font(.headline)
            Text("Weakest first. These come up more often in drills.").font(.footnote).foregroundStyle(.secondary)
            Chart(summary.categories) { c in
                BarMark(x: .value("Accuracy", c.accuracy), y: .value("Category", c.category.title))
                    .foregroundStyle(c.accuracy < 0.6 ? Color.orange : Theme.hero)
                    .annotation(position: .trailing) {
                        Text(Theme.percent(c.accuracy, digits: 0)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
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
            Text("Sessions").font(.headline).padding(.bottom, 6)
            ForEach(sessions.prefix(20)) { s in
                NavigationLink(value: s) {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(s.mode.title).font(.subheadline.weight(.medium))
                            Text(s.startedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(s.correctCount)/\(s.attemptCount)").font(Theme.smallNumber)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
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
                            Image(systemName: a.isCorrect ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(a.isCorrect ? .green : .orange)
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
