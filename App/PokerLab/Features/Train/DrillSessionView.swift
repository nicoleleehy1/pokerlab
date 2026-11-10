import SwiftUI
import SwiftData
import PokerCore
import PokerTraining

struct DrillSessionView: View {
    @State private var model: DrillSessionModel
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    init(kind: DrillKind, isDaily: Bool = false) {
        _model = State(initialValue: DrillSessionModel(kind: kind, isDaily: isDaily))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                switch model.phase {
                case .loading:
                    ProgressView().padding(40)
                case .question, .answered:
                    spotView
                case .finished:
                    summary
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(model.isDaily ? "Daily Drill" : model.kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if model.phase != .finished {
                Button("End") { model.finish() }.accessibilityIdentifier("end-session")
            }
        }
        .sensoryFeedback(trigger: model.feedbackTrigger) { _, _ in
            model.grade?.isCorrect == true ? .success : .error
        }
        .task { model.start(context: context) }
        .onDisappear { model.finish() }
    }

    private var header: some View {
        HStack {
            Text(model.progressText).font(Theme.smallNumber).foregroundStyle(.secondary)
                .accessibilityLabel("Question \(model.progressText)")
            Spacer()
            Label("\(model.tally.streak)", systemImage: "flame")
                .font(Theme.smallNumber)
                .foregroundStyle(model.tally.streak > 0 ? .orange : .secondary)
                .contentTransition(.numericText(value: Double(model.tally.streak)))
                .accessibilityLabel("Streak \(model.tally.streak)")
            Label("\(model.tally.points)", systemImage: "star")
                .font(Theme.smallNumber)
                .contentTransition(.numericText(value: Double(model.tally.points)))
                .accessibilityLabel("\(model.tally.points) points")
        }
        .motionAware(model.tally.points)
    }

    @ViewBuilder private var spotView: some View {
        switch model.spot {
        case .quiz(let s): QuizCard(model: model, spot: s)
        case .potOdds(let s): PotOddsCard(model: model, spot: s)
        case .range(let s): RangeTrainerCard(model: model, spot: s)
        case nil: EmptyView()
        }
        if model.phase == .answered {
            Button {
                model.next()
            } label: {
                Text(model.tally.attempts >= model.length ? "See results" : "Next spot").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("next-spot")
        }
    }

    private var summary: some View {
        VStack(spacing: 16) {
            Image(systemName: model.tally.accuracy >= 0.7 ? "checkmark.seal.fill" : "chart.bar.fill")
                .font(.system(size: 56)).foregroundStyle(.tint).accessibilityHidden(true)
            Text("Session complete").font(.title2.bold())
            HStack(spacing: 24) {
                tile("Accuracy", Theme.percent(model.tally.accuracy, digits: 0))
                tile("Points", "\(model.tally.points)")
                tile("Best streak", "\(model.tally.bestStreak)")
            }
            Button("Done") { dismiss() }.buttonStyle(.borderedProminent).accessibilityIdentifier("session-done")
        }
        .panel()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("session-summary")
    }

    private func tile(_ label: String, _ value: String) -> some View {
        VStack {
            Text(value).font(Theme.mediumNumber)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Equity Quiz

private struct QuizCard: View {
    @Bindable var model: DrillSessionModel
    let spot: EquityQuizSpot

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(spot.category.title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            SpotCards(hero: spot.hero, villainHand: spot.villainHand, villainName: spot.villain?.name, board: spot.board)
            Text("What is your equity?").font(.headline)
            VStack(spacing: 4) {
                Text(Theme.percent(model.guess, digits: 0))
                    .font(Theme.bigNumber)
                    .foregroundStyle(Theme.hero)
                    .contentTransition(.numericText(value: model.guess))
                    .frame(maxWidth: .infinity)
                Slider(value: $model.guess, in: 0...1, step: 0.01) { Text("Your equity guess") }
                    .disabled(model.phase != .question)
                    .accessibilityValue(Theme.percent(model.guess, digits: 0))
                    .accessibilityIdentifier("equity-slider")
            }
            if model.phase == .question {
                Button { Task { await model.submitGuess() } } label: { Text("Lock in").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .accessibilityIdentifier("submit-answer")
            } else if let g = model.grade, let t = model.truth {
                ResultBanner(grade: g, detail: "True equity \(Theme.percent(t)). You were \(String(format: "%.1f", g.errorPoints)) points away.")
            }
        }
        .panel()
    }
}

// MARK: - Pot Odds

private struct PotOddsCard: View {
    let model: DrillSessionModel
    let spot: PotOddsSpot

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(spot.category.title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            SpotCards(hero: spot.hero, villainHand: nil, villainName: spot.villain.name, board: spot.board)
            HStack(spacing: 24) {
                labeled("Pot", "\(spot.pot.formatted()) bb")
                labeled("Bet", "\(spot.bet.formatted()) bb")
                labeled("To call", Theme.percent(spot.requiredEquity) + " equity")
            }
            if model.phase == .question {
                HStack {
                    Button { Task { await model.submitDecision(call: false) } } label: { Text("Fold").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered).controlSize(.large).accessibilityIdentifier("fold")
                    Button { Task { await model.submitDecision(call: true) } } label: { Text("Call").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent).controlSize(.large).accessibilityIdentifier("call")
                }
            } else if let g = model.grade, let t = model.truth {
                let ev = spot.callEV(equity: t)
                ResultBanner(grade: g, detail: "Your equity \(Theme.percent(t)) vs \(Theme.percent(spot.requiredEquity)) needed. Calling is worth \(ev >= 0 ? "+" : "")\(ev.formatted(.number.precision(.fractionLength(1)))) bb.")
            }
        }
        .panel()
    }

    private func labeled(_ l: String, _ v: String) -> some View {
        VStack(alignment: .leading) {
            Text(l).font(.caption).foregroundStyle(.secondary)
            Text(v).font(Theme.smallNumber)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Range Trainer

private struct RangeTrainerCard: View {
    @Bindable var model: DrillSessionModel
    let spot: RangeTrainerSpot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(spot.prompt).font(.headline)
            Text("Tap or drag to paint. Heads-up, 0.5/1 blinds, no ante.").font(.footnote).foregroundStyle(.secondary)
            RangeGridView(values: values, editable: model.phase == .question, outline: outline) { hc, on in
                if on { model.painted.insert(hc) } else { model.painted.remove(hc) }
            }
            HStack {
                Text("\(model.painted.reduce(0) { $0 + $1.comboCount }) combos, \(Theme.percent(Double(model.painted.reduce(0) { $0 + $1.comboCount }) / 1326))")
                    .font(Theme.smallNumber).foregroundStyle(.secondary)
                Spacer()
                if model.phase == .question {
                    Button("Clear") { model.painted = [] }.disabled(model.painted.isEmpty)
                }
            }
            if model.phase == .question {
                Button { Task { await model.submitRange() } } label: { Text("Check against Nash").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large).accessibilityIdentifier("submit-range")
            } else if let g = model.grade, let c = model.comparison {
                ResultBanner(grade: g, detail: "\(Theme.percent(c.accuracy)) of combos match. Missed \(c.missed.count) hands, \(c.extra.count) extra. Orange outlines are misses, red outlines are extras.")
            }
        }
        .panel()
    }

    private var values: [Double] {
        var v = [Double](repeating: 0, count: 169)
        if model.phase == .answered, let c = model.comparison {
            for hc in c.reference { v[hc.index] = 1 }
        } else {
            for hc in model.painted { v[hc.index] = 1 }
        }
        return v
    }

    private func outline(_ hc: HandClass) -> Color? {
        guard model.phase == .answered, let c = model.comparison else { return nil }
        if c.missed.contains(hc) { return .orange }
        if c.extra.contains(hc) { return .red }
        return nil
    }
}

// MARK: - Shared pieces

struct SpotCards: View {
    let hero: HoleCards
    let villainHand: HoleCards?
    let villainName: String?
    let board: CardSet

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("You").font(.caption).foregroundStyle(Theme.hero)
                    HStack(spacing: 4) { CardView(card: hero.high); CardView(card: hero.low) }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Villain").font(.caption).foregroundStyle(.secondary)
                    if let v = villainHand {
                        HStack(spacing: 4) { CardView(card: v.high); CardView(card: v.low) }
                    } else {
                        Text(villainName ?? "Range").font(.subheadline.weight(.medium))
                            .padding(.vertical, 8)
                    }
                }
            }
            if !board.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Board").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 4) { ForEach(Array(board.sortedForDisplay), id: \.self) { CardView(card: $0, baseWidth: 40) } }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct ResultBanner: View {
    let grade: Grade
    let detail: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: grade.isCorrect ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.title2)
                .foregroundStyle(grade.isCorrect ? .green : .orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(grade.verdict.title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
                Text("+\(grade.points) points").font(Theme.smallNumber)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background((grade.isCorrect ? Color.green : Color.orange).opacity(0.12), in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("result-banner")
        .transition(.opacity)
    }
}
