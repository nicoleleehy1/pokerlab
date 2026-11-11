import SwiftUI
import PokerCore

/// One multiple-choice question as the lesson screen shows it.
struct LessonQuestionData: Identifiable, Sendable {
    struct Fact: Hashable, Sendable { let label: String; let value: String }

    let id: Int
    /// Small uppercase label above the prompt (the lesson or concept).
    let topic: String
    let prompt: String
    var heroCards: [Card] = []
    var villainCards: [Card] = []
    var board: [Card] = []
    var facts: [Fact] = []
    let options: [String]
    /// Options graded as correct (several when actions are within the equal-EV tolerance).
    let correct: Set<Int>
    /// Shown after checking, whatever was picked.
    let explanation: String
    /// Optional per-option note, e.g. "Calling loses 0.8 bb (3% of the pot)".
    var optionNotes: [String] = []

    func feedbackTitle(for choice: Int) -> String {
        if correct.contains(choice) { return correct.count > 1 ? "Correct. Both are fine here" : "Correct" }
        let answers = correct.sorted().map { options[$0] }
        return "Not quite. The answer is \(answers.formatted(.list(type: .or)))"
    }

    func feedbackMessage(for choice: Int) -> String {
        guard choice < optionNotes.count, !optionNotes[choice].isEmpty else { return explanation }
        return optionNotes[choice] + " " + explanation
    }
}

/// Result of a finished lesson.
struct LessonOutcome: Sendable {
    let correct: Int
    let total: Int
    /// Index of the chosen option per question.
    let choices: [Int]
}

/// Drives a lesson: picks, checks, advances.
@MainActor @Observable
final class LessonRunner {
    let title: String
    private(set) var questions: [LessonQuestionData] = []
    private(set) var index = 0
    private(set) var picked: Int?
    private(set) var checked = false
    private(set) var choices: [Int] = []
    private(set) var loadError: String?
    var isLoaded: Bool { !questions.isEmpty }
    var isFinished: Bool { isLoaded && choices.count == questions.count && !checked }

    private let load: @Sendable () async throws -> [LessonQuestionData]

    init(title: String, load: @escaping @Sendable () async throws -> [LessonQuestionData]) {
        self.title = title
        self.load = load
    }

    func start() async {
        guard questions.isEmpty else { return }
        do { questions = try await load() } catch { loadError = error.localizedDescription }
    }

    var current: LessonQuestionData? { index < questions.count ? questions[index] : nil }
    var progress: Double { questions.isEmpty ? 0 : Double(choices.count) / Double(questions.count) }
    var correctCount: Int { zip(questions, choices).filter { $0.correct.contains($1) }.count }

    func pick(_ i: Int) { if !checked { picked = i } }

    func check() {
        guard let picked, !checked else { return }
        checked = true
        choices.append(picked)
    }

    func next() {
        guard checked else { return }
        checked = false
        picked = nil
        if index < questions.count - 1 { index += 1 }
    }

    var outcome: LessonOutcome { LessonOutcome(correct: correctCount, total: questions.count, choices: choices) }
}

/// Lesson screen from docs/design/Lesson.dc.html: close button, segmented progress, the spot,
/// a 2x2 answer grid, a feedback panel and one 52 pt primary button.
struct LessonView: View {
    @State var runner: LessonRunner
    var onFinish: (LessonOutcome) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.top, 8)
                .padding(.bottom, 24)
            if runner.isFinished {
                summary
            } else if let q = runner.current {
                question(q)
            } else if let error = runner.loadError {
                ContentUnavailableView("Couldn't build this lesson", systemImage: "exclamationmark.triangle", description: Text(error))
                Spacer()
            } else {
                Spacer()
                ProgressView("Dealing").tint(Theme.ink)
                Spacer()
            }
        }
        .screenPadding()
        .padding(.bottom, 16)
        .background(Theme.background)
        .task { await runner.start() }
        .sensoryFeedback(trigger: runner.checked) { _, checked in
            guard checked, let q = runner.current, let pick = runner.choices.last else { return nil }
            return q.correct.contains(pick) ? .success : .error
        }
    }

    private var topBar: some View {
        HStack(spacing: 16) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(.body, weight: .regular))
                    .foregroundStyle(Theme.muted)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .padding(.leading, -10)
            .accessibilityLabel("Close lesson")
            .accessibilityIdentifier("close-lesson")
            ProgressTrack(value: runner.progress)
                .accessibilityLabel("Lesson progress")
            Text("\(min(runner.choices.count + (runner.checked ? 0 : 1), max(runner.questions.count, 1)))/\(max(runner.questions.count, 1))")
                .font(Theme.caption.monospacedDigit())
                .foregroundStyle(Theme.muted)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder private func question(_ q: LessonQuestionData) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(q.topic).eyebrowStyle()
                    Text(q.prompt)
                        .font(Theme.questionTitle)
                        .tracking(-0.4)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("lesson-prompt")
                }
                if !q.heroCards.isEmpty || !q.villainCards.isEmpty || !q.board.isEmpty || !q.facts.isEmpty { spotCard(q) }
                answerGrid(q)
                if runner.checked, let pick = runner.choices.last {
                    FeedbackPanel(title: q.feedbackTitle(for: pick), message: q.feedbackMessage(for: pick))
                        .accessibilityIdentifier("lesson-feedback")
                        .transition(.opacity)
                }
            }
            .padding(.bottom, 16)
        }
        .scrollBounceBehavior(.basedOnSize)
        .motionAware(runner.checked)
        primaryButton
    }

    private func spotCard(_ q: LessonQuestionData) -> some View {
        VStack(spacing: 20) {
            if !q.heroCards.isEmpty {
                HStack {
                    Text("Your hand").font(Theme.caption).foregroundStyle(Theme.muted)
                    Spacer()
                    HStack(spacing: 8) { ForEach(q.heroCards, id: \.self) { CardView(card: $0, baseWidth: 48) } }
                }
                .accessibilityElement(children: .combine)
            }
            if !q.villainCards.isEmpty {
                if !q.heroCards.isEmpty { Rectangle().fill(Theme.subtle).frame(height: 1) }
                HStack {
                    Text("Villain").font(Theme.caption).foregroundStyle(Theme.muted)
                    Spacer()
                    HStack(spacing: 8) { ForEach(q.villainCards, id: \.self) { CardView(card: $0, baseWidth: 48) } }
                }
                .accessibilityElement(children: .combine)
            }
            if !q.board.isEmpty {
                if !q.heroCards.isEmpty || !q.villainCards.isEmpty { Rectangle().fill(Theme.subtle).frame(height: 1) }
                HStack {
                    Text("Board").font(Theme.caption).foregroundStyle(Theme.muted)
                    Spacer()
                    HStack(spacing: 6) { ForEach(q.board, id: \.self) { CardView(card: $0, baseWidth: 36) } }
                }
                .accessibilityElement(children: .combine)
            }
            ForEach(Array(q.facts.enumerated()), id: \.offset) { i, fact in
                if i > 0 || !q.heroCards.isEmpty || !q.villainCards.isEmpty || !q.board.isEmpty { Rectangle().fill(Theme.subtle).frame(height: 1) }
                HStack(alignment: .firstTextBaseline) {
                    Text(fact.label).font(Theme.caption).foregroundStyle(Theme.muted)
                    Spacer(minLength: 16)
                    Text(fact.value).font(Theme.label).multilineTextAlignment(.trailing)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .panel()
    }

    private func answerGrid(_ q: LessonQuestionData) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            ForEach(q.options.indices, id: \.self) { i in
                AnswerButton(label: q.options[i], state: state(of: i, in: q)) { runner.pick(i) }
                    .accessibilityIdentifier("answer-\(i)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Answers")
    }

    private func state(of i: Int, in q: LessonQuestionData) -> AnswerButton.State {
        if runner.checked {
            if q.correct.contains(i) { return .right }
            if runner.picked == i { return .wrong }
            return .idle
        }
        return runner.picked == i ? .selected : .idle
    }

    private var primaryButton: some View {
        Button {
            if runner.checked {
                runner.next()
            } else {
                runner.check()
                if let q = runner.current, let pick = runner.choices.last {
                    AccessibilityNotification.Announcement(q.feedbackTitle(for: pick)).post()
                }
            }
        } label: {
            Text(runner.checked ? (runner.choices.count == runner.questions.count ? "See results" : "Next question") : "Check")
        }
        .buttonStyle(.primary)
        .disabled(runner.picked == nil)
        .padding(.top, 8)
        .accessibilityIdentifier("lesson-primary")
    }

    private var summary: some View {
        let o = runner.outcome
        return VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
            VStack(alignment: .leading, spacing: 8) {
                Text(runner.title).eyebrowStyle()
                Text("Lesson complete").font(Theme.screenTitle).tracking(-0.5).accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("lesson-summary")
            }
            HStack(spacing: 12) {
                StatTile(title: "Correct", value: "\(o.correct)/\(o.total)")
                StatTile(title: "Accuracy", value: Theme.percent(Double(o.correct) / Double(max(o.total, 1)), digits: 0))
            }
            Spacer()
            Button("Continue") { onFinish(o); dismiss() }
                .buttonStyle(.primary)
                .accessibilityIdentifier("lesson-done")
        }
    }
}

/// One cell of the 2x2 answer grid. States match the prototype: selected and right answers
/// get a 2 pt ink border (right ones also a zinc-100 fill); a wrong pick gets a dashed border.
struct AnswerButton: View {
    enum State { case idle, selected, right, wrong }
    let label: String
    let state: State
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(label.count <= 6 ? Theme.mediumNumber.weight(.medium) : Theme.label)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, minHeight: 64)
                .background(state == .right ? Theme.subtle : Theme.background, in: .rect(cornerRadius: Theme.controlRadius))
                .overlay { border }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(state == .selected || state == .wrong ? [.isSelected] : [])
        .accessibilityValue(state == .right ? "Correct answer" : state == .wrong ? "Your answer, incorrect" : "")
    }

    @ViewBuilder private var border: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.controlRadius)
        switch state {
        case .idle: shape.strokeBorder(Theme.border, lineWidth: 1)
        case .selected, .right: shape.strokeBorder(Theme.ink, lineWidth: 2)
        case .wrong: shape.strokeBorder(Theme.faint, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
    }
}
