import SwiftUI
import SwiftData
import PokerCore
import PokerTraining
import PokerCourse

/// One row of the lesson path.
struct PathLesson: Identifiable, Hashable {
    enum Status: Hashable { case done, current, locked }
    let id: String
    let title: String
    let meta: String
    let status: Status
}

/// Learn tab from docs/design/Main.dc.html: streak pill, daily goal, unit header and the lesson
/// path with done / current / locked lessons, driven by the PokerCourse curriculum.
struct LearnView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \LessonResult.date) private var results: [LessonResult]
    @Query private var attempts: [DrillAttempt]
    @State private var activeLesson: Lesson?
    @State private var selectedUnit: Int?

    private var progress: CourseProgress {
        CourseProgress(records: results.map(\.record),
                       extraActiveDays: Set(attempts.map { DailyDrill.dayNumber(for: $0.date) }),
                       today: DailyDrill.dayNumber())
    }

    var body: some View {
        let progress = self.progress
        let path = progress.path()
        let unit = Curriculum.units.first { $0.number == selectedUnit } ?? progress.currentUnit()
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                    ScreenHeader(overline: Date.now.formatted(.dateTime.weekday(.wide)), title: "Learn") {
                        Pill(symbol: "flame", text: "\(progress.streak) day streak")
                            .accessibilityIdentifier("streak-pill")
                    }
                    dailyGoalCard(progress)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Unit \(unit.number)").eyebrowStyle()
                        Text(unit.title).font(Theme.sectionTitle).tracking(-0.2).accessibilityAddTraits(.isHeader)
                        Text(unit.summary).font(Theme.caption).foregroundStyle(Theme.muted).padding(.top, 2)
                    }
                    LessonPath(lessons: path.filter { $0.unit == unit.number }.map { item in
                        PathLesson(id: item.id, title: item.lesson.title, meta: meta(item, unit: unit),
                                   status: item.status == .done ? .done : item.status == .current ? .current : .locked)
                    }) { tapped in
                        activeLesson = Curriculum.lesson(tapped.id)
                    }
                    unitList(progress: progress, path: path, showing: unit.number)
                }
                .screenPadding()
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
            .background(Theme.background)
            .toolbar(.hidden, for: .navigationBar)
            .fullScreenCover(item: $activeLesson) { lesson in
                LessonView(runner: LessonRunner(title: lesson.title) { try await Curriculum.lessonQuestions(lesson) }) { outcome in
                    save(outcome, lesson: lesson)
                }
            }
        }
    }

    private func meta(_ item: CourseProgress.PathItem, unit: CourseUnit) -> String {
        switch item.status {
        case .done: "Completed · \(Theme.percent(item.bestAccuracy ?? 0, digits: 0)) accuracy"
        case .current: "\(item.lesson.questionCount) questions · about 4 min"
        case .locked: unit.isAvailable ? "\(item.lesson.questionCount) questions" : "Unlocks with the river solver"
        }
    }

    private func save(_ outcome: LessonOutcome, lesson: Lesson) {
        guard outcome.total > 0 else { return }
        context.insert(LessonResult(lessonID: lesson.id, correct: outcome.correct, total: outcome.total,
                                    meanLossFraction: outcome.meanLossFraction))
        try? context.save()
        selectedUnit = nil
    }

    private func dailyGoalCard(_ p: CourseProgress) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Daily goal").font(Theme.label)
                Spacer()
                Text("\(min(p.xpToday, p.dailyGoalXP)) of \(p.dailyGoalXP) XP").font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.muted)
            }
            ProgressTrack(value: Double(p.xpToday) / Double(p.dailyGoalXP))
                .accessibilityLabel("Daily goal")
        }
        .panel()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("daily-goal")
    }

    private func unitList(progress: CourseProgress, path: [CourseProgress.PathItem], showing: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Course").eyebrowStyle()
            RowGroup {
                ForEach(Curriculum.units) { unit in
                    let items = path.filter { $0.unit == unit.number }
                    let done = items.filter { $0.status == .done }.count
                    Button { selectedUnit = unit.number } label: {
                        ListRow(symbol: unit.isAvailable ? (done == items.count ? "checkmark.circle" : "circle") : "lock",
                                title: "\(unit.number). \(unit.title)",
                                subtitle: unit.isAvailable ? "\(done) of \(items.count) lessons" : "Needs the river solver",
                                showsChevron: unit.number != showing)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(unit.number == showing ? .isSelected : [])
                    .accessibilityIdentifier("unit-\(unit.number)")
                }
            }
            Text("\(progress.totalXP) XP total").font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.muted)
        }
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
                        } else if lesson.status == .done {
                            Button("Practise again") { start(lesson) }
                                .buttonStyle(OutlineButtonStyle(height: 32))
                                .padding(.top, 8)
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
