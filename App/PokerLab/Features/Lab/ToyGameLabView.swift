import SwiftUI
import Charts
import PokerSolver

/// Runs CFR live on a toy game and plots exploitability against iterations.
@MainActor @Observable
final class ToyGameLabModel {
    enum GameChoice: String, CaseIterable, Identifiable { case kuhn = "Kuhn poker", clairvoyance = "Clairvoyance"; var id: Self { self } }
    enum Algorithm: String, CaseIterable, Identifiable {
        case cfr = "CFR", cfrPlus = "CFR+", dcfr = "DCFR"
        var id: Self { self }
        var variant: ToyCFR.Variant {
            switch self { case .cfr: .vanilla; case .cfrPlus: .cfrPlus; case .dcfr: .dcfrDefault }
        }
    }
    struct Point: Identifiable, Equatable {
        var id: Int { iteration }
        let iteration: Int
        let exploitability: Double
    }

    var gameChoice = GameChoice.kuhn
    var algorithm = Algorithm.dcfr
    var betSize = 1.0
    nonisolated static let iterations = 5_000

    private(set) var points: [Point] = []
    private(set) var strategy: [Double] = []
    private(set) var value: Double?
    private(set) var solveMilliseconds = 0.0
    private(set) var isRunning = false
    private(set) var solvedGame: ToyGame?
    private var task: Task<Void, Never>?

    var game: ToyGame { gameChoice == .kuhn ? .kuhn : .clairvoyance(bet: betSize) }
    var theoryValue: Double { gameChoice == .kuhn ? ToyGame.kuhnValue : ToyGame.clairvoyanceValue(bet: betSize) }
    var theoryText: String { gameChoice == .kuhn ? "−1/18" : "(1 + 2s) / (2 (1 + s))" }

    /// Solves from scratch. With `animated`, pauses briefly between checkpoints so the chart
    /// visibly converges (the solve time shown excludes those pauses).
    func solve(animated: Bool) {
        task?.cancel()
        points = []; strategy = []; value = nil; solveMilliseconds = 0
        let game = self.game, variant = algorithm.variant
        solvedGame = game
        isRunning = true
        task = Task.detached(priority: .userInitiated) { [weak self] in
            var cfr = ToyCFR(game: game, variant: variant)
            let clock = ContinuousClock()
            var solve = Duration.zero
            var next = 1
            while cfr.iteration < Self.iterations, !Task.isCancelled {
                let t0 = clock.now
                cfr.run(iterations: next - cfr.iteration)
                solve += clock.now - t0
                let avg = cfr.average
                let point = Point(iteration: cfr.iteration, exploitability: game.exploitability(avg))
                let value = game.value(avg), ms = Double(solve.components.attoseconds) * 1e-15 + Double(solve.components.seconds) * 1000
                await self?.publish(point, strategy: avg, value: value, ms: ms)
                next = min(Self.iterations, max(next + 1, Int(Double(next) * 1.25)))
                if animated { try? await Task.sleep(for: .milliseconds(25)) }
            }
            await self?.finish()
        }
    }

    private func publish(_ p: Point, strategy: [Double], value: Double, ms: Double) {
        points.append(p); self.strategy = strategy; self.value = value; solveMilliseconds = ms
    }
    private func finish() { isRunning = false }
}

struct ToyGameLabView: View {
    @State private var model = ToyGameLabModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text(model.gameChoice == .kuhn
                     ? "Three cards, one bet. CFR plays the game against itself; its average strategy converges to the equilibrium, worth −1/18 chip per hand to the first player."
                     : "The bettor knows whether they hold the nuts or air; the caller holds a bluff-catcher. Equilibrium bluffs s/(1+s) of air and calls 1/(1+s).")
                    .font(Theme.caption).foregroundStyle(Theme.muted)
                controls
                resultCard
                if let game = model.solvedGame, !model.strategy.isEmpty { strategyCard(game) }
            }
            .screenPadding()
            .padding(.vertical, 16)
        }
        .background(Theme.background)
        .navigationTitle("Toy games")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if model.points.isEmpty { model.solve(animated: !reduceMotion) } }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Game", selection: $model.gameChoice) {
                ForEach(ToyGameLabModel.GameChoice.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            if model.gameChoice == .clairvoyance {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Bet size").font(Theme.caption).foregroundStyle(Theme.muted)
                        Spacer()
                        Text("\(model.betSize.formatted(.number.precision(.fractionLength(0...2))))× pot").font(Theme.smallNumber)
                    }
                    Slider(value: $model.betSize, in: 0.25...3, step: 0.25) { Text("Bet size") }
                        .tint(Theme.ink)
                        .accessibilityValue("\(model.betSize.formatted()) times the pot")
                }
            }
            Picker("Algorithm", selection: $model.algorithm) {
                ForEach(ToyGameLabModel.Algorithm.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            Button(model.isRunning ? "Solving…" : "Solve") { model.solve(animated: !reduceMotion) }
                .buttonStyle(.primary)
                .disabled(model.isRunning)
                .accessibilityIdentifier("toy-solve")
        }
    }

    private var resultCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Exploitability").font(Theme.label)
                Spacer()
                Text("chips per hand, log scale").font(.system(.caption, design: .monospaced)).foregroundStyle(Theme.muted)
            }
            Chart(model.points.filter { $0.exploitability > 0 }) { p in
                LineMark(x: .value("Iteration", p.iteration), y: .value("Exploitability", p.exploitability))
                    .foregroundStyle(Theme.ink)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            }
            .chartXScale(domain: 1...ToyGameLabModel.iterations, type: .log)
            .chartYScale(domain: 1e-5...1, type: .log)
            .chartYAxis { AxisMarks(values: [1e-5, 1e-4, 1e-3, 1e-2, 1e-1, 1]) { v in
                AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text(d, format: .number.notation(.scientific)) } }
            } }
            .chartXAxis { AxisMarks(values: [1, 10, 100, 1000, 5000]) }
            .frame(height: 180)
            .accessibilityLabel("Exploitability against iterations")
            .accessibilityValue(model.points.last.map { "\($0.exploitability.formatted(.number.notation(.scientific))) after \($0.iteration) iterations" } ?? "")
            .accessibilityIdentifier("toy-chart")
            HStack(spacing: 12) {
                stat("Iterations", model.points.last.map { "\($0.iteration)" } ?? "–")
                stat("Game value", model.value.map { $0.formatted(.number.precision(.fractionLength(4))) } ?? "–")
                stat("Theory", model.theoryValue.formatted(.number.precision(.fractionLength(4))))
            }
            Text("Theory: \(model.theoryText). Solve time \(model.solveMilliseconds.formatted(.number.precision(.fractionLength(1)))) ms on this device, excluding exploitability checks\(reduceMotion ? "" : " and the animation pauses").")
                .font(Theme.caption).foregroundStyle(Theme.muted)
        }
        .panel()
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(Theme.smallNumber).contentTransition(.numericText())
            Text(label).font(Theme.caption).foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func strategyCard(_ game: ToyGame) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Average strategy").font(Theme.label).padding(.bottom, 8)
            ForEach(Array(game.infosets.enumerated()), id: \.offset) { i, set in
                if i > 0 { Rectangle().fill(Theme.subtle).frame(height: 1) }
                HStack(alignment: .firstTextBaseline) {
                    Text(set.name).font(Theme.caption).foregroundStyle(set.player == 0 ? Theme.ink : Theme.muted)
                    Spacer(minLength: 12)
                    Text(set.actions.indices.map { "\(set.actions[$0]) \(Theme.percent(model.strategy[set.offset + $0], digits: 0))" }.joined(separator: " · "))
                        .font(Theme.smallNumber)
                        .multilineTextAlignment(.trailing)
                }
                .padding(.vertical, 10)
                .accessibilityElement(children: .combine)
            }
            Text("Ink rows are the first player (bettor), grey rows the second.")
                .font(Theme.caption).foregroundStyle(Theme.muted).padding(.top, 8)
        }
        .panel()
    }
}
