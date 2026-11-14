import Foundation

/// Builds the prompt for an on-device language model (Apple's Foundation Models) to explain a
/// graded answer in plain language, and checks the reply against the solver's numbers.
///
/// The model only rephrases: every number it may use is in the context, and any reply that
/// mentions a number not in the context is rejected (`unsupportedNumbers`).
public enum ExplanationPrompt {
    public static let instructions = """
    You are a friendly poker coach. In two or three short sentences, explain the grade in plain \
    language for a beginner. Start by naming the best option. Higher EV is always better. Use only \
    the facts and numbers given; never invent cards, draws, reads or numbers. No markdown, no \
    lists, no greetings.
    """

    /// Everything the solver knows about the spot, as plain text.
    public static func context(_ q: Question) -> String {
        var lines: [String] = []
        lines.append("Question: \(q.prompt)")
        if !q.hero.isEmpty { lines.append("Hero's cards: " + q.hero.map(\.description).joined(separator: " ")) }
        if !q.villain.isEmpty { lines.append("Villain's cards: " + q.villain.map(\.description).joined(separator: " ")) }
        if !q.board.isEmpty { lines.append("Board: " + q.board.map(\.description).joined(separator: " ")) }
        for f in q.facts { lines.append("\(f.label): \(f.value)") }
        let best = q.options.indices.max { q.options[$0].ev < q.options[$1].ev }!
        for (i, o) in q.options.enumerated() {
            let value = q.kind == .decision ? "EV \(Fmt.num(o.ev, 2)) \(q.evUnit)" : "\(Fmt.num(-o.ev, 1)) points from the answer"
            lines.append("Option \(o.label): \(value)\(i == best ? " (best)" : "")")
        }
        lines.append("Solver note: \(q.explanation)")
        return lines.joined(separator: "\n")
    }

    /// The request for one answer: the spot plus the comparison the explanation must make.
    public static func prompt(_ q: Question, choice: Int) -> String {
        let best = bestIndex(q)
        let g = q.grade(choice)
        var lines = [context(q)]
        if q.kind == .decision {
            lines.append("Best option: \(q.options[best].label) (EV \(Fmt.num(q.options[best].ev, 2)) \(q.evUnit)).")
            lines.append("The player chose \(q.options[choice].label) (EV \(Fmt.num(q.options[choice].ev, 2)) \(q.evUnit)), giving up \(Fmt.num(g.evLoss, 2)) \(q.evUnit), \(Fmt.pct(g.lossFraction, 1)) of the pot.")
        } else {
            lines.append("Correct answer: \(q.options[best].label). The player answered \(q.options[choice].label).")
        }
        lines.append("Grade: \(g.verdict.title). Answers within 1% of the pot of the best option count as correct.")
        lines.append("Explain the grade.")
        return lines.joined(separator: "\n")
    }

    static func bestIndex(_ q: Question) -> Int { q.options.indices.max { q.options[$0].ev < q.options[$1].ev }! }

    /// Every number in the prompt (what a reply may use).
    public static func allowedText(_ q: Question) -> String {
        q.options.indices.map { prompt(q, choice: $0) }.joined(separator: "\n")
    }

    /// A reply must name the best option and must not call any other option best.
    public static func isConsistent(_ reply: String, _ q: Question) -> Bool {
        let text = reply.lowercased()
        let best = q.options[bestIndex(q)].label.lowercased()
        guard text.contains(best) else { return false }
        for (i, o) in q.options.enumerated() where i != bestIndex(q) {
            let label = o.label.lowercased()
            for pattern in ["best option is \(label)", "\(label) is best", "\(label) is the best", "best play is \(label)", "best choice is \(label)"]
            where text.contains(pattern) { return false }
        }
        return true
    }

    /// Whether a reply may be shown: consistent with the grade and using only the solver's numbers.
    public static func accept(_ reply: String, for q: Question) -> Bool {
        isConsistent(reply, q) && unsupportedNumbers(in: reply, context: allowedText(q)).isEmpty
    }

    /// Numbers in `reply` that don't appear in `context` (ignoring one-digit counts like "two").
    public static func unsupportedNumbers(in reply: String, context: String) -> [String] {
        let allowed = Set(numbers(in: context).map(normalize))
        return numbers(in: reply).filter { n in
            let v = normalize(n)
            return !allowed.contains(v) && !(Double(v).map { $0 == $0.rounded() && abs($0) < 10 } ?? false)
        }
    }

    static func numbers(in text: String) -> [String] {
        var out: [String] = [], cur = ""
        for ch in text {
            if ch.isNumber || (ch == "." && !cur.isEmpty) { cur.append(ch) }
            else { if !cur.isEmpty { out.append(cur) }; cur = "" }
        }
        if !cur.isEmpty { out.append(cur) }
        return out.map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }
    }

    /// "15.90" -> "15.9", "40.0" -> "40".
    static func normalize(_ s: String) -> String {
        guard let d = Double(s) else { return s }
        return d == d.rounded() ? String(Int(d)) : String(d)
    }
}
