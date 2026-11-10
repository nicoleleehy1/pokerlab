import SwiftUI
import Charts
import PokerCore
import PokerTraining

struct LabTab: View {
    @Environment(AppRouter.self) private var router

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.labPath) {
            EquityLabView()
                .navigationDestination(for: AppRouter.Destination.self) { d in
                    switch d {
                    case .solver: SolverView()
                    case .camera: CameraScanView()
                    default: EmptyView()
                    }
                }
        }
    }
}

struct EquityLabView: View {
    @Environment(AppRouter.self) private var router
    @State private var model = EquityLabModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                handsPanel
                boardPanel
                resultPanel
                if model.convergence.count > 1 { convergencePanel }
                toolsPanel
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Equity Lab")
        .toolbar {
            Button("Clear", systemImage: "arrow.counterclockwise") { model.clear() }
                .disabled(model.usedCards.isEmpty)
        }
        .sheet(item: $model.pickerSlot) { slot in
            CardPickerSheet(title: slot.title, used: model.usedCards, current: model.card(at: slot)) { card in
                model.set(card, at: slot)
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: model.completedRuns)
        .onAppear { if model.snapshot == nil { model.recompute() } }
        .onChange(of: router.pendingLabSpot.map(ObjectIdentifier.init), initial: true) {
            guard let spot = router.pendingLabSpot else { return }
            router.pendingLabSpot = nil
            model.load(hero: spot.hero, villain: spot.villainRange, villainCards: spot.villainCards, board: spot.board)
        }
    }

    private var handsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("You").font(.headline).foregroundStyle(Theme.hero)
            CardSlotsRow(cards: model.hero, label: "Your") { model.pickerSlot = .hero($0) }
            Divider()
            HStack {
                Text("Villain").font(.headline).foregroundStyle(Theme.villain)
                Spacer()
                Picker("Villain", selection: $model.villainMode) {
                    ForEach(EquityLabModel.VillainMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .onChange(of: model.villainMode) { model.recompute() }
            }
            if model.villainMode == .hand {
                CardSlotsRow(cards: model.villain, label: "Villain") { model.pickerSlot = .villain($0) }
            } else {
                TextField("Range, e.g. AKs, QQ+, A5s-A2s", text: $model.villainRangeText)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                    .padding(10)
                    .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 8))
                    .onSubmit { model.recompute() }
                    .accessibilityIdentifier("villain-range-field")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(NamedRange.presets, id: \.name) { preset in
                            Button(preset.name) { model.villainRangeText = preset.notation; model.recompute() }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                }
                if let error = model.rangeError {
                    Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.red)
                }
            }
        }
        .panel()
    }

    private var boardPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Board").font(.headline)
            CardSlotsRow(cards: model.board, label: "Board") { model.pickerSlot = .board($0) }
        }
        .panel()
    }

    @ViewBuilder private var resultPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let snap = model.snapshot {
                EquityBars(hero: snap.equities[0], villain: snap.equities[1], standardError: snap.standardErrors[0])
                HStack {
                    Label(snap.isExact ? "\(snap.samples.formatted()) boards enumerated" : "\(snap.samples.formatted()) simulated deals",
                          systemImage: snap.isExact ? "checkmark.seal" : "dice")
                        .contentTransition(.numericText(value: Double(snap.samples)))
                    Spacer()
                    if model.isRunning { ProgressView().controlSize(.small) }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                HStack(spacing: 16) {
                    stat("Win", snap.winProbabilities[0])
                    stat("Tie", snap.tieProbabilities[0])
                    stat("Lose", 1 - snap.winProbabilities[0] - snap.tieProbabilities[0])
                }
            } else {
                Label(model.message ?? "Pick cards to start", systemImage: "hand.point.up.left")
                    .foregroundStyle(.secondary)
            }
            if let message = model.message, model.snapshot != nil {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .panel()
        .accessibilityIdentifier("equity-result")
    }

    private func stat(_ label: String, _ x: Double) -> some View {
        VStack(alignment: .leading) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(Theme.percent(x)).font(Theme.smallNumber).contentTransition(.numericText(value: x))
        }
        .accessibilityElement(children: .combine)
    }

    private var convergencePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Convergence").font(.headline)
            Text("Your equity estimate as deals accumulate, with its 95% interval.")
                .font(.footnote).foregroundStyle(.secondary)
            Chart(model.convergence) { p in
                AreaMark(x: .value("Deals", p.trials), yStart: .value("Low", p.low), yEnd: .value("High", p.high))
                    .foregroundStyle(Theme.hero.opacity(0.18))
                LineMark(x: .value("Deals", p.trials), y: .value("Equity", p.equity))
                    .foregroundStyle(Theme.hero)
                    .interpolationMethod(.monotone)
            }
            .chartYScale(domain: yDomain)
            .chartYAxis { AxisMarks(format: FloatingPointFormatStyle<Double>.Percent().precision(.fractionLength(0))) }
            .chartXAxis { AxisMarks(format: IntegerFormatStyle<Int>().notation(.compactName)) }
            .frame(height: 180)
            .accessibilityLabel("Convergence chart")
            .accessibilityValue(model.convergence.last.map { "Latest estimate \(Theme.percent($0.equity)) after \($0.trials) deals" } ?? "")
        }
        .panel()
    }

    private var yDomain: ClosedRange<Double> {
        let lows = model.convergence.map(\.low), highs = model.convergence.map(\.high)
        let lo = max(0, (lows.min() ?? 0) - 0.01), hi = min(1, (highs.max() ?? 1) + 0.01)
        return lo < hi ? lo...hi : 0...1
    }

    private var toolsPanel: some View {
        VStack(spacing: 0) {
            NavigationLink(value: AppRouter.Destination.solver) {
                Label("Push/Fold Solver", systemImage: "function").frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
            }
            Divider()
            NavigationLink(value: AppRouter.Destination.camera) {
                Label("Scan a Table", systemImage: "camera.viewfinder").frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
            }
        }
        .panel()
    }
}

/// A spot pushed into the Equity Lab from elsewhere (camera, App Intents).
final class LabSpot: Sendable {
    let hero: [Card], villainCards: [Card], board: [Card]
    let villainRange: HandRange?
    init(hero: [Card], villainCards: [Card] = [], villainRange: HandRange? = nil, board: [Card]) {
        self.hero = hero; self.villainCards = villainCards; self.villainRange = villainRange; self.board = board
    }
}
