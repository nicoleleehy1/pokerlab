import Testing
@testable import PokerSolver

@Suite("Toy games: CFR on Kuhn poker and the clairvoyance game")
struct ToyGameTests {
    @Test func kuhnTreeShape() {
        let g = ToyGame.kuhn
        #expect(g.infosets.count == 12)       // 6 per player
        #expect(g.actionCount == 24)
    }

    /// The headline check: CFR's average strategy reaches the known game value -1/18.
    @Test("Kuhn converges to value -1/18", arguments: [ToyCFR.Variant.vanilla, .cfrPlus, .dcfrDefault])
    func kuhnConverges(_ variant: ToyCFR.Variant) {
        var cfr = ToyCFR(game: .kuhn, variant: variant)
        cfr.run(iterations: 20_000)
        let avg = cfr.average
        let value = ToyGame.kuhn.value(avg)
        let exploit = ToyGame.kuhn.exploitability(avg)
        #expect(abs(value - ToyGame.kuhnValue) < 1e-3, "\(variant.name): value \(value)")
        #expect(exploit < 1e-3, "\(variant.name): exploitability \(exploit)")
    }

    @Test func kuhnEquilibriumStructure() {
        var cfr = ToyCFR(game: .kuhn, variant: .dcfrDefault)
        cfr.run(iterations: 20_000)
        let s = cfr.average
        let g = ToyGame.kuhn
        func p(_ name: String, _ action: String) -> Double {
            let set = g.infosets.first { $0.name == name }!
            return s[set.offset + set.actions.firstIndex(of: action)!]
        }
        let alpha = p("J · first to act", "Bet")
        #expect(alpha <= 1.0 / 3 + 0.01)
        #expect(abs(p("K · first to act", "Bet") - 3 * alpha) < 0.02)
        #expect(abs(p("Q · facing a bet", "Call") - 1.0 / 3) < 0.02)
        #expect(abs(p("J · after a check", "Bet") - 1.0 / 3) < 0.02)
        #expect(p("K · facing a bet", "Call") > 0.99)
        #expect(p("J · facing a bet", "Call") < 0.01)
    }

    /// Exploitability of a known non-equilibrium strategy, computed by hand: if player 1
    /// always calls and always checks back, player 0's best response gains; uniform random
    /// play must be exploitable.
    @Test func uniformStrategyIsExploitable() {
        let g = ToyGame.kuhn
        let uniform = [Double](repeating: 0.5, count: g.actionCount)
        #expect(g.exploitability(uniform) > 0.1)
    }

    @Test("Clairvoyance game matches closed form", arguments: [0.5, 1.0, 2.0])
    func clairvoyance(_ s: Double) {
        let g = ToyGame.clairvoyance(bet: s)
        var cfr = ToyCFR(game: g, variant: .dcfrDefault)
        cfr.run(iterations: 5_000)
        let avg = cfr.average
        #expect(abs(g.value(avg) - ToyGame.clairvoyanceValue(bet: s)) < 1e-3)
        #expect(g.exploitability(avg) < 1e-3)
        let bluff = g.infosets.first { $0.name == "Bettor · air" }!
        let call = g.infosets.first { $0.name == "Caller · facing a bet" }!
        #expect(abs(avg[bluff.offset + 1] - s / (1 + s)) < 0.01, "bluff frequency")
        #expect(abs(avg[call.offset + 1] - 1 / (1 + s)) < 0.01, "call frequency (MDF)")
    }

    @Test func exploitabilityFallsWithIterations() {
        var cfr = ToyCFR(game: .kuhn, variant: .cfrPlus)
        cfr.run(iterations: 10)
        let early = ToyGame.kuhn.exploitability(cfr.average)
        cfr.run(iterations: 990)
        let late = ToyGame.kuhn.exploitability(cfr.average)
        #expect(late < early / 10)
    }
}
