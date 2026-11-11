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
            VStack(spacing: 20) {
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
            .screenPadding()
            .padding(.vertical, 16)
        }
        .background(Theme.background)
        .navigationTitle(model.isDaily ? "Daily Spot" : model.kind.title)
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
            Text(model.progressText).font(Theme.smallNumber).foregroundStyle(Theme.muted)
                .accessibilityLabel("Question \(model.progressText)")
            Spacer()
            Label("\(model.tally.streak)", systemImage: "flame")
                .font(Theme.smallNumber)
                .foregroundStyle(model.tally.streak > 0 ? Theme.ink : Theme.muted)
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
                Text(model.tally.attempts >= model.length ? "See results" : "Next spot")
            }
            .buttonStyle(.primary)
            .accessibilityIdentifier("next-spot")
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Session complete").font(Theme.sectionTitle).accessibilityAddTraits(.isHeader)
            HStack(spacing: 12) {
                StatTile(title: "Accuracy", value: Theme.percent(model.tally.accuracy, digits: 0))
                StatTile(title: "Points", value: "\(model.tally.points)")
                StatTile(title: "Best streak", value: "\(model.tally.bestStreak)")
            }
            Button("Done") { dismiss() }.buttonStyle(.primary).accessibilityIdentifier("session-done")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("session-summary")
    }
}

// MARK: - Equity Quiz

private struct QuizCard: View {
    @Bindable var model: DrillSessionModel
    let spot: EquityQuizSpot

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(spot.category.title).eyebrowStyle()
            SpotCards(hero: spot.hero, villainHand: spot.villainHand, villainName: spot.villain?.name, board: spot.board)
            Text("What is your equity?").font(Theme.label)
            VStack(spacing: 4) {
                Text(Theme.percent(model.guess, digits: 0))
                    .font(Theme.bigNumber)
                    .foregroundStyle(Theme.ink)
                    .contentTransition(.numericText(value: model.guess))
                    .frame(maxWidth: .infinity)
                Slider(value: $model.guess, in: 0...1, step: 0.01) { Text("Your equity guess") }
                    .tint(Theme.ink)
                    .disabled(model.phase != .question)
                    .accessibilityValue(Theme.percent(model.guess, digits: 0))
                    .accessibilityIdentifier("equity-slider")
            }
            if model.phase == .question {
                Button { Task { await model.submitGuess() } } label: { Text("Lock in") }
                    .buttonStyle(.primary)
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
            Text(spot.category.title).eyebrowStyle()
            SpotCards(hero: spot.hero, villainHand: nil, villainName: spot.villain.name, board: spot.board)
            HStack(spacing: 24) {
                labeled("Pot", "\(spot.pot.formatted()) bb")
                labeled("Bet", "\(spot.bet.formatted()) bb")
                labeled("To call", Theme.percent(spot.requiredEquity) + " equity")
            }
            if model.phase == .question {
                HStack {
                    Button { Task { await model.submitDecision(call: false) } } label: { Text("Fold").frame(maxWidth: .infinity) }
                        .buttonStyle(OutlineButtonStyle(height: 52)).accessibilityIdentifier("fold")
                    Button { Task { await model.submitDecision(call: true) } } label: { Text("Call") }
                        .buttonStyle(.primary).accessibilityIdentifier("call")
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
            Text(l).font(Theme.caption).foregroundStyle(Theme.muted)
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
            Text(spot.prompt).font(Theme.label)
            Text("Tap or drag to paint. Heads-up, 0.5/1 blinds, no ante.").font(Theme.caption).foregroundStyle(Theme.muted)
            RangeGridView(values: values, editable: model.phase == .question, outline: outline) { hc, on in
                if on { model.painted.insert(hc) } else { model.painted.remove(hc) }
            }
            HStack {
                Text("\(model.painted.reduce(0) { $0 + $1.comboCount }) combos, \(Theme.percent(Double(model.painted.reduce(0) { $0 + $1.comboCount }) / 1326))")
                    .font(Theme.smallNumber).foregroundStyle(Theme.muted)
                Spacer()
                if model.phase == .question {
                    Button("Clear") { model.painted = [] }.buttonStyle(.outline).disabled(model.painted.isEmpty)
                }
            }
            if model.phase == .question {
                Button { Task { await model.submitRange() } } label: { Text("Check against Nash") }
                    .buttonStyle(.primary).accessibilityIdentifier("submit-range")
            } else if let g = model.grade, let c = model.comparison {
                ResultBanner(grade: g, detail: "\(Theme.percent(c.accuracy)) of combos match. Missed \(c.missed.count) hands, \(c.extra.count) extra. Ink outlines are hands you missed, red outlines are extras.")
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
        if c.missed.contains(hc) { return Theme.ink }
        if c.extra.contains(hc) { return Theme.red }
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
                    Text("You").font(Theme.caption).foregroundStyle(Theme.muted)
                    HStack(spacing: 4) { CardView(card: hero.high); CardView(card: hero.low) }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Villain").font(Theme.caption).foregroundStyle(Theme.muted)
                    if let v = villainHand {
                        HStack(spacing: 4) { CardView(card: v.high); CardView(card: v.low) }
                    } else {
                        Text(villainName ?? "Range").font(Theme.label)
                            .padding(.vertical, 8)
                    }
                }
            }
            if !board.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Board").font(Theme.caption).foregroundStyle(Theme.muted)
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
            Image(systemName: grade.isCorrect ? "checkmark.circle" : "xmark.circle")
                .font(.title3)
                .foregroundStyle(Theme.ink)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(grade.verdict.title).font(.system(.subheadline, weight: .semibold))
                Text(detail).font(Theme.caption).foregroundStyle(Theme.body).fixedSize(horizontal: false, vertical: true)
                Text("+\(grade.points) points").font(Theme.smallNumber).foregroundStyle(Theme.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(Theme.wash, in: .rect(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("result-banner")
        .transition(.opacity)
    }
}
