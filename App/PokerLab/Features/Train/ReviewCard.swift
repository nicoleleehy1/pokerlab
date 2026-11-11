import SwiftUI
import SwiftData
import PokerCourse

/// Adaptive review: FSRS brings back spot templates as they're due, and Elo fills the rest of
/// the session with the templates you're predicted to get right about 75% of the time.
struct ReviewCard: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \LessonResult.date) private var results: [LessonResult]
    @Query(sort: \PlayerProfile.createdAt) private var profiles: [PlayerProfile]
    @State private var session: ReviewSession?

    struct ReviewSession: Identifiable { let id = UUID(); let plan: [TemplateID] }

    private var progress: CourseProgress {
        CourseProgress(records: results.map(\.record), today: DailyDrill.dayNumber())
    }
    private var state: AdaptiveState { profiles.first?.adaptive ?? AdaptiveState() }

    var body: some View {
        let pool = Curriculum.unlockedTemplates(progress)
        let due = state.due(at: PlayerProfile.adaptiveNow()).filter(pool.contains)
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Adaptive review").font(Theme.label)
                    Spacer()
                    Text(due.isEmpty ? "Nothing due" : "\(due.count) due").font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.muted)
                }
                Text("Ten fresh spots: what's due for review first, then questions pitched at about 75% success.")
                    .font(Theme.caption).foregroundStyle(Theme.muted)
            }
            Button("Start review") {
                session = ReviewSession(plan: state.plan(count: 10, pool: pool, at: PlayerProfile.adaptiveNow()))
            }
            .buttonStyle(.primary)
            .disabled(pool.isEmpty)
            .accessibilityIdentifier("start-review")
        }
        .panel()
        .fullScreenCover(item: $session) { s in
            LessonView(runner: LessonRunner(title: "Adaptive review") { try await Curriculum.reviewQuestions(s.plan) }) { outcome in
                guard outcome.total > 0 else { return }
                context.insert(LessonResult(lessonID: "review", correct: outcome.correct, total: outcome.total,
                                            meanLossFraction: outcome.meanLossFraction))
                PlayerProfile.current(in: context).recordAdaptive(outcome)
                try? context.save()
            }
        }
    }
}

/// Per-concept mastery from the Elo model (predicted success on an average template).
struct MasteryCard: View {
    let state: AdaptiveState

    var body: some View {
        let concepts = Concept.allCases.filter { (state.elo.answers[$0] ?? 0) > 0 }
        VStack(alignment: .leading, spacing: 12) {
            Text("Concept mastery").font(Theme.label)
            if concepts.isEmpty {
                Text("Answer a few course questions to see your mastery per concept.").font(Theme.caption).foregroundStyle(Theme.muted)
            }
            ForEach(concepts, id: \.self) { c in
                HStack(spacing: 12) {
                    Text(c.title).font(Theme.caption).frame(width: 120, alignment: .leading)
                    ProgressTrack(value: state.elo.mastery(c))
                    Text(Theme.percent(state.elo.mastery(c), digits: 0)).font(Theme.smallNumber).frame(width: 44, alignment: .trailing)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(c.title), \(Theme.percent(state.elo.mastery(c), digits: 0)) mastery")
            }
        }
        .panel()
    }
}
