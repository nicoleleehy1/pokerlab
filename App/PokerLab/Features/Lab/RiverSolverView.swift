import SwiftUI
import Charts
import PokerCore
import PokerSolver

/// Solves a full-range river on the device and shows convergence and each range's strategy.
@MainActor @Observable
final class RiverLabModel {
    enum RangePreset: String, CaseIterable, Identifiable {
        case full = "Any two cards", study = "BB vs BTN"
        var id: Self { self }
        var ranges: (HandRange, HandRange) {
            switch self {
            case .full: (.all, .all)
            case .study: (try! HandRange("22+, A2s+, K2s+, Q4s+, J6s+, T6s+, 96s+, 85s+, 74s+, 63s+, 53s+, 43s, A2o+, K7o+, Q8o+, J8o+, T8o+, 98o"),
                          try! HandRange("22+, A2s+, K5s+, Q8s+, J8s+, T8s+, 97s+, 86s+, 75s+, 65s, 54s, A7o+, K9o+, QTo+, JTo"))
            }
        }
    }
    struct Point: Identifiable, Equatable { var id: Int { iteration }; let iteration: Int; let exploitability: Double }
    struct Row: Identifiable, Equatable { var id: String { label }; let label: String; let frequency: Double }

    var preset = RangePreset.study
    var sizes = 2
    private(set) var board: [Card] = []
    private(set) var points: [Point] = []
    private(set) var oopRoot: [Row] = []
    private(set) var ipAfterCheck: [Row] = []
    private(set) var solveMilliseconds = 0.0
    private(set) var isRunning = false
    private(set) var summary = ""
    private var task: Task<Void, Never>?
    nonisolated static let target = 0.3

    init() { deal() }

    func deal() {
        board = Array(Card.all.shuffled().prefix(5)).sorted(by: >)
        solve()
    }

    func solve() {
        task?.cancel()
        points = []; oopRoot = []; ipAfterCheck = []; solveMilliseconds = 0; summary = ""
        let (oop, ip) = preset.ranges
        let sizes: [Double] = [[0.75], [0.33, 0.75], [0.33, 0.75, 1.5]][self.sizes - 1]
        let spot = RiverSpot(board: board, pot: 10, stack: 100, oop: oop, ip: ip,
                             config: RiverTreeConfig(betSizes: sizes, raiseSizes: [0.75], allowAllIn: true, maxBets: 3))
        isRunning = true
        task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let solver = try? RiverSolver(spot: spot) else { await self?.fail(); return }
            let clock = ContinuousClock()
            var time = Duration.zero
            while solver.iteration < 2000, !Task.isCancelled {
                let t0 = clock.now
                solver.iterate(10)
                time += clock.now - t0
                let e = solver.exploitability()
                let ms = Double(time.components.seconds) * 1000 + Double(time.components.attoseconds) * 1e-15
                await self?.publish(Point(iteration: solver.iteration, exploitability: e), ms: ms)
                if e <= Self.target { break }
            }
            let root = solver.nodes[solver.root].actions.map(\.label)
            let oopRows = zip(root, solver.rangeFrequencies(path: [])).map { Row(label: $0, frequency: $1) }
            let ipLabels = solver.nodes[solver.node(path: [0])].actions.map(\.label)
            let ipRows = zip(ipLabels, solver.rangeFrequencies(path: [0])).map { Row(label: $0, frequency: $1) }
            let h = solver.handCounts, k = solver.canonicalHandCounts
            let text = "\(h.oop) vs \(h.ip) hands\(solver.usesIsomorphism ? " (\(k.oop) vs \(k.ip) after suit isomorphism)" : ""), \(solver.decisionNodeCount) decision nodes, \(String(format: "%.2f", Double(solver.storageBytes) / 1_048_576)) MB of tables."
            await self?.finish(oop: oopRows, ip: ipRows, summary: text)
        }
    }

    private func publish(_ p: Point, ms: Double) { points.append(p); solveMilliseconds = ms }
    private func finish(oop: [Row], ip: [Row], summary: String) {
        oopRoot = oop; ipAfterCheck = ip; self.summary = summary; isRunning = false
    }
    private func fail() { isRunning = false; summary = "No valid deal for these ranges on this board." }
}

struct RiverSolverView: View {
    @State private var model = RiverLabModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("Both players' whole ranges on one river, solved on this device with Discounted CFR until a perfect opponent could win less than 0.3% of the pot.")
                    .font(Theme.caption).foregroundStyle(Theme.muted)
                boardRow
                controls
                convergenceCard
                if !model.oopRoot.isEmpty {
                    strategyCard("Big blind, first to act", model.oopRoot)
                    strategyCard("Button, after a check", model.ipAfterCheck)
                }
                if !model.summary.isEmpty {
                    Text(model.summary).font(Theme.caption).foregroundStyle(Theme.muted)
                }
            }
            .screenPadding()
            .padding(.vertical, 16)
        }
        .background(Theme.background)
        .navigationTitle("River solver")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var boardRow: some View {
        HStack(spacing: 8) {
            ForEach(model.board, id: \.self) { CardView(card: $0, baseWidth: 48) }
        }
        .dynamicTypeSize(...DynamicTypeSize.large)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Board: " + model.board.map(\.spokenName).joined(separator: ", "))
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Ranges", selection: $model.preset) {
                ForEach(RiverLabModel.RangePreset.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Bet sizes", selection: $model.sizes) {
                Text("1 size").tag(1); Text("2 sizes").tag(2); Text("3 sizes").tag(3)
            }
            .pickerStyle(.segmented)
            HStack(spacing: 12) {
                Button("New board") { model.deal() }
                    .buttonStyle(OutlineButtonStyle(height: 52))
                    .accessibilityIdentifier("river-new-board")
                Button(model.isRunning ? "Solving…" : "Solve") { model.solve() }
                    .buttonStyle(.primary)
                    .disabled(model.isRunning)
                    .accessibilityIdentifier("river-solve")
            }
        }
    }

    private var convergenceCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Exploitability").font(Theme.label)
                Spacer()
                Text("% of pot, log scale").font(.system(.caption, design: .monospaced)).foregroundStyle(Theme.muted)
            }
            Chart {
                RuleMark(y: .value("Target", RiverLabModel.target))
                    .foregroundStyle(Theme.border)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                ForEach(model.points.filter { $0.exploitability > 0 }) { p in
                    LineMark(x: .value("Iteration", p.iteration), y: .value("Exploitability", p.exploitability))
                        .foregroundStyle(Theme.ink)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                }
            }
            .chartYScale(type: .log)
            .frame(height: 160)
            .accessibilityLabel("Exploitability against iterations")
            .accessibilityValue(model.points.last.map { "\(String(format: "%.2f", $0.exploitability)) percent of the pot after \($0.iteration) iterations" } ?? "")
            .accessibilityIdentifier("river-chart")
            HStack(spacing: 12) {
                stat("Iterations", model.points.last.map { "\($0.iteration)" } ?? "–")
                stat("Exploitability", model.points.last.map { String(format: "%.2f%%", $0.exploitability) } ?? "–")
                stat("Solve time", "\(Int(model.solveMilliseconds.rounded())) ms")
            }
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

    private func strategyCard(_ title: String, _ rows: [RiverLabModel.Row]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(Theme.label)
            ForEach(rows) { row in
                HStack(spacing: 12) {
                    Text(row.label).font(Theme.caption).frame(width: 96, alignment: .leading)
                    ProgressTrack(value: row.frequency)
                    Text(Theme.percent(row.frequency, digits: 0)).font(Theme.smallNumber).frame(width: 44, alignment: .trailing)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(row.label) \(Theme.percent(row.frequency, digits: 0))")
            }
        }
        .panel()
    }
}
