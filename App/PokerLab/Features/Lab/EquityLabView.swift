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
                    case .toyGames: ToyGameLabView()
                    case .riverSolver: RiverSolverView()
                    case .camera: CameraScanView()
                    default: EmptyView()
                    }
                }
        }
    }
}

/// Equity Lab from docs/design/Lab.dc.html: two hand rows with large tabular percentages, a
/// win/tie/lose bar, five dashed board slots, and the convergence chart behind "Show the math".
struct EquityLabView: View {
    @Environment(AppRouter.self) private var router
    @State private var model = EquityLabModel()
    @State private var showMath = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                ScreenHeader(title: "Lab") {
                    Button { model.clear() } label: {
                        Label("Reset", systemImage: "arrow.counterclockwise").labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.outline)
                    .disabled(model.usedCards.isEmpty)
                    .accessibilityIdentifier("lab-reset")
                }
                VStack(spacing: 12) {
                    heroRow
                    villainRow
                }
                resultBar
                boardSlots
                mathDisclosure
                tools
            }
            .screenPadding()
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
        .background(Theme.background)
        .toolbar(.hidden, for: .navigationBar)
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

    // MARK: Hand rows

    private var heroRow: some View {
        handRow(label: "You", description: describe(model.hero), equity: model.snapshot?.equities[0], muted: false) {
            CardSlotsRow(cards: model.hero, label: "Your", baseWidth: 40) { model.pickerSlot = .hero($0) }
        }
        .panel(padding: 16)
        .accessibilityIdentifier("hero-row")
    }

    private var villainRow: some View {
        VStack(alignment: .leading, spacing: 16) {
            handRow(label: "Villain", description: villainDescription, equity: model.snapshot?.equities[1], muted: true) {
                if model.villainMode == .hand {
                    CardSlotsRow(cards: model.villain, label: "Villain", baseWidth: 40) { model.pickerSlot = .villain($0) }
                } else {
                    Image(systemName: "square.grid.3x3")
                        .font(.title3)
                        .foregroundStyle(Theme.muted)
                        .frame(width: 86, height: 55)
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border, lineWidth: 1))
                        .accessibilityHidden(true)
                }
            }
            Picker("Villain holds", selection: $model.villainMode) {
                ForEach(EquityLabModel.VillainMode.allCases) { Text($0 == .hand ? "Exact hand" : "Range").tag($0) }
            }
            .pickerStyle(.segmented)
            .onChange(of: model.villainMode) { model.recompute() }
            if model.villainMode == .range { rangeEditor }
        }
        .panel(padding: 16)
    }

    @ViewBuilder private var rangeEditor: some View {
        TextField("Range, e.g. AKs, QQ+, A5s-A2s", text: $model.villainRangeText)
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled()
            .font(.system(.subheadline, design: .monospaced))
            .padding(.horizontal, 12)
            .frame(minHeight: 40)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border, lineWidth: 1))
            .onSubmit { model.recompute() }
            .accessibilityIdentifier("villain-range-field")
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(NamedRange.presets, id: \.name) { preset in
                    Button(preset.name) { model.villainRangeText = preset.notation; model.recompute() }
                        .buttonStyle(OutlineButtonStyle(height: 32))
                }
            }
        }
        if let error = model.rangeError {
            Label(error, systemImage: "exclamationmark.triangle").font(Theme.caption).foregroundStyle(Theme.red)
        }
    }

    private func handRow<Cards: View>(label: String, description: String, equity: Double?, muted: Bool,
                                      @ViewBuilder cards: () -> Cards) -> some View {
        HStack(spacing: 16) {
            cards().dynamicTypeSize(...DynamicTypeSize.large)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(Theme.caption).foregroundStyle(Theme.muted)
                Text(description).font(Theme.label).lineLimit(2).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(equity.map { Theme.percent($0) } ?? "–")
                .font(Theme.bigNumber)
                .tracking(-0.5)
                .foregroundStyle(muted ? Theme.muted : Theme.ink)
                .contentTransition(.numericText(value: equity ?? 0))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .accessibilityLabel(equity.map { "\(label) equity \(Theme.percent($0))" } ?? "No result yet")
        }
        .motionAware(equity ?? 0)
    }

    private func describe(_ cards: [Card?]) -> String {
        guard let a = cards[0], let b = cards[1] else { return "Pick two cards" }
        return HoleCards(a, b).handClass.spokenName.capitalizedFirst
    }

    private var villainDescription: String {
        if model.villainMode == .hand { return describe(model.villain) }
        let text = model.villainRangeText.trimmingCharacters(in: .whitespaces)
        return NamedRange.presets.first { $0.notation == text }?.name ?? "Custom range"
    }

    // MARK: Result, board, math

    @ViewBuilder private var resultBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let snap = model.snapshot {
                let win = snap.winProbabilities[0], tie = snap.tieProbabilities[0]
                SplitBar(win: win, tie: tie)
                HStack {
                    Text("Win \(Theme.percent(win))")
                    Spacer()
                    Text("Tie \(Theme.percent(tie))")
                    Spacer()
                    Text("Lose \(Theme.percent(max(0, 1 - win - tie)))")
                }
                .font(Theme.eyebrow.monospacedDigit().weight(.regular))
                .foregroundStyle(Theme.muted)
                .accessibilityElement(children: .combine)
            } else {
                SplitBar(win: 0)
                Text(model.message ?? "Pick cards to start").font(Theme.caption).foregroundStyle(Theme.muted)
            }
            if let message = model.message, model.snapshot != nil {
                Text(message).font(Theme.caption).foregroundStyle(Theme.muted)
            }
        }
        .accessibilityIdentifier("equity-result")
    }

    private var boardSlots: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Board").font(Theme.caption).foregroundStyle(Theme.muted)
            CardSlotsRow(cards: model.board, label: "Board", baseWidth: 56, spacing: 8) { model.pickerSlot = .board($0) }
                .dynamicTypeSize(...DynamicTypeSize.large)
        }
    }

    private var mathDisclosure: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                showMath.toggle()
            } label: {
                HStack(spacing: 8) {
                    Text(showMath ? "Hide the math" : "Show the math").font(Theme.label)
                    Image(systemName: "chevron.down")
                        .font(.footnote)
                        .rotationEffect(.degrees(showMath ? 180 : 0))
                        .accessibilityHidden(true)
                    Spacer()
                    if model.isRunning { ProgressView().controlSize(.small).tint(Theme.muted) }
                }
                .foregroundStyle(Theme.ink)
                .frame(minHeight: 44)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityValue(showMath ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("show-math")
            if showMath { convergenceCard.transition(.opacity) }
        }
        .motionAware(showMath)
    }

    private var convergenceCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Convergence").font(Theme.label)
                Spacer()
                if let snap = model.snapshot {
                    Text("\(snap.samples.formatted(.number.notation(.compactName))) \(snap.isExact ? "boards · exact" : "deals · Monte Carlo")")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Theme.muted)
                }
            }
            if model.convergence.count > 1 {
                Chart {
                    if let last = model.convergence.last {
                        RuleMark(y: .value("Final", last.equity))
                            .foregroundStyle(Theme.border)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                    ForEach(model.convergence) { p in
                        AreaMark(x: .value("Deals", p.trials), yStart: .value("Low", p.low), yEnd: .value("High", p.high))
                            .foregroundStyle(Theme.subtle)
                        LineMark(x: .value("Deals", p.trials), y: .value("Equity", p.equity))
                            .foregroundStyle(Theme.ink)
                            .lineStyle(StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                    }
                }
                .chartYScale(domain: yDomain)
                .chartYAxis { AxisMarks(format: FloatingPointFormatStyle<Double>.Percent().precision(.fractionLength(0))) }
                .chartXAxis { AxisMarks(format: IntegerFormatStyle<Int>().notation(.compactName)) }
                .frame(height: 120)
                .accessibilityLabel("Convergence chart")
                .accessibilityValue(model.convergence.last.map { "Estimate \(Theme.percent($0.equity)) after \($0.trials) deals" } ?? "")
                Text("Your equity estimate as deals accumulate, with its 95% interval shaded. Exact results enumerate every board.")
                    .font(Theme.caption).foregroundStyle(Theme.muted)
            } else {
                Text(model.snapshot?.isExact == true
                     ? "Exact: every remaining board was enumerated, so there is nothing to converge."
                     : "Pick a spot to watch the estimate converge.")
                    .font(Theme.caption).foregroundStyle(Theme.muted)
            }
        }
        .panel()
    }

    private var yDomain: ClosedRange<Double> {
        let lows = model.convergence.map(\.low), highs = model.convergence.map(\.high)
        let lo = max(0, (lows.min() ?? 0) - 0.01), hi = min(1, (highs.max() ?? 1) + 0.01)
        return lo < hi ? lo...hi : 0...1
    }

    private var tools: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tools").eyebrowStyle()
            RowGroup {
                NavigationLink(value: AppRouter.Destination.riverSolver) {
                    ListRow(symbol: "square.stack.3d.up", title: "River solver", subtitle: "Full ranges, solved on this device")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("tool-river")
                NavigationLink(value: AppRouter.Destination.solver) {
                    ListRow(symbol: "function", title: "Push/Fold Solver", subtitle: "Heads-up Nash ranges, solved live")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("tool-solver")
                NavigationLink(value: AppRouter.Destination.toyGames) {
                    ListRow(symbol: "chart.line.downtrend.xyaxis", title: "Toy games", subtitle: "Watch CFR solve Kuhn poker live")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("tool-toys")
                NavigationLink(value: AppRouter.Destination.camera) {
                    ListRow(symbol: "camera.viewfinder", title: "Scan a Table", subtitle: "Read real cards with the camera")
                }
                .buttonStyle(.plain)
            }
        }
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// A spot pushed into the Equity Lab from elsewhere (camera, App Intents).
final class LabSpot: Sendable {
    let hero: [Card], villainCards: [Card], board: [Card]
    let villainRange: HandRange?
    init(hero: [Card], villainCards: [Card] = [], villainRange: HandRange? = nil, board: [Card]) {
        self.hero = hero; self.villainCards = villainCards; self.villainRange = villainRange; self.board = board
    }
}
