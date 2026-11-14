import Foundation
import PokerCourse

extension LessonQuestionData {
    /// Presents a generated course question. Decisions get per-option EV-loss verdicts with
    /// the published tolerance; estimates and facts get the plain explanation.
    init(_ q: Question, index: Int, topic: String) {
        let graded = q.options.indices.map { q.grade($0) }
        var titles: [String] = []
        var notes: [String] = []
        if q.kind == .decision {
            let best = q.options.indices.max { q.options[$0].ev < q.options[$1].ev }!
            for (i, g) in graded.enumerated() {
                let ev = "\(q.options[i].label) is worth \(Self.signed(q.options[i].ev, unit: q.evUnit))"
                switch g.verdict {
                case .best:
                    titles.append("Best")
                    notes.append("\(ev).")
                case .correct:
                    titles.append("Correct. Equal EV")
                    notes.append("\(ev), within \(Self.pct(Grading.equalEVTolerance)) of the pot of \(q.options[best].label), so both count.")
                default:
                    titles.append("\(g.verdict.title). \(q.options[best].label) is best")
                    notes.append("\(ev): it gives up \(Self.amount(g.evLoss, unit: q.evUnit)) (\(Self.pct(g.lossFraction)) of the pot).")
                }
            }
        }
        self.init(id: index, topic: topic, prompt: q.prompt, heroCards: q.hero, villainCards: q.villain, board: q.board,
                  facts: q.facts.map { .init(label: $0.label, value: $0.value) },
                  options: q.options.map(\.label), correct: q.correctOptions, explanation: q.explanation,
                  optionNotes: notes, optionTitles: titles, lossFractions: graded.map(\.lossFraction),
                  templateID: q.id.split(separator: "-").first.map(String.init),
                  source: q)
    }

    static func pct(_ x: Double) -> String { x.formatted(.percent.precision(.fractionLength(0...1))) }
    static func amount(_ x: Double, unit: String) -> String {
        "\(x.formatted(.number.precision(.fractionLength(0...2)))) \(unit == "% of prizes" ? "points of the prize pool" : unit)"
    }
    static func signed(_ x: Double, unit: String) -> String {
        (x >= 0 ? "+" : "−") + amount(abs(x), unit: unit)
    }
}

extension Curriculum {
    /// A lesson's questions converted for the lesson screen.
    static func lessonQuestions(_ lesson: Lesson, seed: UInt64 = .random(in: 1...UInt64.max)) async throws -> [LessonQuestionData] {
        let qs = try await questions(for: lesson, seed: seed)
        return qs.enumerated().map { LessonQuestionData($1, index: $0, topic: $1.concept.title) }
    }
}

extension Curriculum {
    /// An adaptive review session's questions.
    static func reviewQuestions(_ plan: [TemplateID], seed: UInt64 = .random(in: 1...UInt64.max)) async throws -> [LessonQuestionData] {
        let qs = try await questions(plan: plan, seed: seed)
        return qs.enumerated().map { LessonQuestionData($1, index: $0, topic: $1.concept.title) }
    }
}
