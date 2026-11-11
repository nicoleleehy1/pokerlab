import SwiftUI
import SwiftData
import PokerCore
import PokerTraining

/// One row of the lesson path.
struct PathLesson: Identifiable, Hashable {
    enum Status: Hashable { case done, current, locked }
    let id: String
    let title: String
    let meta: String
    let status: Status
}

/// Learn tab from docs/design/Main.dc.html: streak pill, daily goal, unit header and the lesson
/// path with done / current / locked lessons.
struct LearnView: View {
    @Query(sort: \DrillAttempt.date, order: .reverse) private var attempts: [DrillAttempt]
    @State private var activeLesson: PathLesson?

    private let dailyGoal = 5
    private var dayStreak: Int {
        let days = Set(attempts.map { DailyDrill.dayNumber(for: $0.date) })
        return DailyStreak.current(days: days, today: DailyDrill.dayNumber())
    }
    private var todayCount: Int { attempts.filter { Calendar.current.isDateInToday($0.date) }.count }

    private var lessons: [PathLesson] {
        [
            PathLesson(id: "equity-1", title: "Hand vs hand", meta: "10 questions · about 4 min", status: .current),
            PathLesson(id: "equity-2", title: "Hand vs range", meta: "10 questions", status: .locked),
            PathLesson(id: "equity-3", title: "Draws on the flop", meta: "10 questions", status: .locked),
        ]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                    ScreenHeader(overline: Date.now.formatted(.dateTime.weekday(.wide)), title: "Learn") {
                        Pill(symbol: "flame", text: "\(dayStreak) day streak")
                            .accessibilityIdentifier("streak-pill")
                    }
                    dailyGoalCard
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Unit 2").eyebrowStyle()
                        Text("Equity vs ranges").font(Theme.sectionTitle).tracking(-0.2).accessibilityAddTraits(.isHeader)
                    }
                    LessonPath(lessons: lessons) { activeLesson = $0 }
                }
                .screenPadding()
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
            .background(Theme.background)
            .toolbar(.hidden, for: .navigationBar)
            .fullScreenCover(item: $activeLesson) { lesson in
                LessonView(runner: LessonRunner(title: lesson.title) { try await SampleLessons.equityQuestions() })
            }
        }
    }

    private var dailyGoalCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Daily goal").font(Theme.label)
                Spacer()
                Text("\(min(todayCount, dailyGoal)) of \(dailyGoal) drills").font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.muted)
            }
            ProgressTrack(value: Double(todayCount) / Double(dailyGoal))
                .accessibilityLabel("Daily goal")
        }
        .panel()
        .accessibilityElement(children: .combine)
    }
}

/// Vertical lesson path: a 32 pt status circle per lesson joined by a 1 pt line.
struct LessonPath: View {
    let lessons: [PathLesson]
    let start: (PathLesson) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lessons.enumerated()), id: \.element.id) { i, lesson in
                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 0) {
                        marker(lesson.status)
                        if i < lessons.count - 1 {
                            Rectangle().fill(Theme.border).frame(width: 1).frame(minHeight: 20, maxHeight: .infinity)
                        }
                    }
                    .frame(width: 32)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(lesson.title).font(Theme.label)
                            .foregroundStyle(lesson.status == .locked ? Theme.faint : Theme.ink)
                        Text(lesson.meta).font(Theme.caption).foregroundStyle(Theme.muted)
                        if lesson.status == .current {
                            Button { start(lesson) } label: {
                                HStack(spacing: 8) {
                                    Text("Continue lesson")
                                    Image(systemName: "arrow.right").accessibilityHidden(true)
                                }
                            }
                            .buttonStyle(.compactPrimary)
                            .padding(.top, 12)
                            .accessibilityIdentifier("continue-lesson")
                        }
                    }
                    .padding(.top, 4)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(lesson.title), \(statusText(lesson.status)). \(lesson.meta)")
            }
        }
    }

    private func statusText(_ s: PathLesson.Status) -> String {
        switch s { case .done: "completed"; case .current: "current lesson"; case .locked: "locked" }
    }

    @ViewBuilder private func marker(_ status: PathLesson.Status) -> some View {
        switch status {
        case .done:
            Circle().fill(Theme.ink).frame(width: 32, height: 32)
                .overlay(Image(systemName: "checkmark").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.onInk))
        case .current:
            Circle().strokeBorder(Theme.ink, lineWidth: 2).frame(width: 32, height: 32)
                .overlay(Circle().fill(Theme.ink).frame(width: 10, height: 10))
        case .locked:
            Circle().strokeBorder(Theme.border, lineWidth: 1).frame(width: 32, height: 32)
                .overlay(Image(systemName: "lock").font(.system(size: 12)).foregroundStyle(Theme.faint))
        }
    }
}

/// Equity questions with four choices, built from the Equity Quiz generator.
enum SampleLessons {
    static func equityQuestions(count: Int = 10, seed: UInt64 = UInt64.random(in: 1...UInt64.max)) async throws -> [LessonQuestionData] {
        var out: [LessonQuestionData] = []
        for i in 0..<count {
            let category = EquityQuiz.categories[i % EquityQuiz.categories.count]
            let spot = EquityQuiz.generate(category, seed: seed &+ UInt64(i))
            let truth = try await spot.solve()
            let options = choices(around: truth, seed: seed &+ UInt64(i))
            let correct = options.indices.min { abs(options[$0] - truth) < abs(options[$1] - truth) }!
            out.append(LessonQuestionData(
                id: i, topic: category.title,
                prompt: spot.villain == nil ? "How often does your hand win against theirs?" : "How often does your hand win against this range?",
                heroCards: [spot.hero.high, spot.hero.low],
                villainCards: spot.villainHand.map { [$0.high, $0.low] } ?? [],
                board: spot.board.sortedForDisplay,
                facts: spot.villain.map { [.init(label: "Villain", value: $0.name)] } ?? [],
                options: options.map { Theme.percent($0, digits: 0) }, correct: [correct],
                explanation: "Your equity is \(Theme.percent(truth)) (\(spot.board.count < 3 ? "every board enumerated" : "exact"))."))
        }
        return out
    }

    /// Four answers at least 10 points apart, one of them within 5 points of the truth.
    static func choices(around truth: Double, seed: UInt64) -> [Double] {
        var rng = Xoshiro256(seed: seed)
        let slot = Int(rng.next(below: 4))
        let start = min(max((truth * 100).rounded() - Double(slot) * 13, 2), 98 - 39)
        return (0..<4).map { (start + Double($0) * 13) / 100 }
    }
}
