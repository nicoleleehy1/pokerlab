import Testing
@testable import PokerCourse

@Suite("On-device explanation prompt")
struct ExplanationPromptTests {
    let q = Question(id: "t", concept: .callOrFold, kind: .decision, prompt: "Villain bets 12 bb into 18 bb. Call or fold?",
                     facts: [.init("Pot", "18 bb"), .init("Bet", "12 bb")],
                     options: [.init("Fold", ev: 0), .init("Call", ev: 15.93)], pot: 30,
                     explanation: "Your equity is 66.5% and a call needs 28.6%.")

    @Test func contextCarriesEveryNumberAndTheBestOption() {
        let c = ExplanationPrompt.context(q)
        #expect(c.contains("Option Call: EV 15.93 bb (best)"))
        #expect(c.contains("Option Fold: EV 0 bb"))
        #expect(c.contains("66.5%"))
        let p = ExplanationPrompt.prompt(q, choice: 0)
        #expect(p.contains("Best option: Call (EV 15.93 bb)."))
        #expect(p.contains("The player chose Fold (EV 0 bb), giving up 15.93 bb, 53.1% of the pot."))
        #expect(p.contains("Grade: Blunder."))
    }

    /// Replies may only reuse the solver's numbers.
    @Test func rejectsInventedNumbers() {
        let c = ExplanationPrompt.context(q)
        #expect(ExplanationPrompt.unsupportedNumbers(in: "Calling needs 28.6% and you have 66.5%, so it earns 15.93 bb.", context: c).isEmpty)
        #expect(ExplanationPrompt.unsupportedNumbers(in: "You win about 70% of the time.", context: c) == ["70"])
        #expect(ExplanationPrompt.unsupportedNumbers(in: "Fold loses 3.5 bb.", context: c) == ["3.5"])
        // Small whole numbers ("2 players", "3 cards") are allowed.
        #expect(ExplanationPrompt.unsupportedNumbers(in: "With 2 cards to come.", context: c).isEmpty)
    }

    /// Replies that get the logic backwards are rejected even when every number is right.
    @Test func rejectsReversedLogic() {
        #expect(ExplanationPrompt.accept("Call is best: it is worth 15.93 bb and folding is worth 0 bb.", for: q))
        #expect(!ExplanationPrompt.accept("The best option is fold because 0 bb is safer than 15.93 bb.", for: q))
        #expect(!ExplanationPrompt.accept("Folding keeps things simple.", for: q))         // never names the best option
    }
}
