import SwiftUI
import PokerCore
import PokerTraining

/// Practice tab: today's shared spot, the free-play drills and reference charts.
struct PracticeView: View {
    @Environment(AppRouter.self) private var router

    private var todaySpot: EquityQuizSpot {
        let seed = DailyDrill.seed()
        return EquityQuiz.generate(EquityQuiz.categories[Int(seed % 4)], seed: seed)
    }

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.practicePath) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                    ScreenHeader(title: "Practice")
                    dailyCard
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Drills").eyebrowStyle()
                        RowGroup {
                            ForEach(DrillKind.allCases) { kind in
                                NavigationLink(value: AppRouter.Destination.drill(kind)) {
                                    ListRow(symbol: kind.symbol, title: kind.title, subtitle: kind.blurb)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("drill-\(kind.rawValue)")
                            }
                        }
                        Text("Each session is 10 spots. PokerLab repeats the categories you miss more often.")
                            .font(Theme.caption).foregroundStyle(Theme.muted)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Reference").eyebrowStyle()
                        RowGroup {
                            NavigationLink(value: AppRouter.Destination.solver) {
                                ListRow(symbol: "square.grid.3x3", title: "Push/fold Nash charts", subtitle: "Solved live with CFR+")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .screenPadding()
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
            .background(Theme.background)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: AppRouter.Destination.self) { d in
                switch d {
                case .drill(let kind): DrillSessionView(kind: kind)
                case .dailyDrill: DrillSessionView(kind: .equityQuiz, isDaily: true)
                case .solver: SolverView()
                case .toyGames: ToyGameLabView()
                case .camera: CameraScanView()
                case .settings: SettingsView()
                }
            }
        }
    }

    private var dailyCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Daily spot").font(Theme.label)
                Text("Same spot for everyone today. How much equity does your hand have?")
                    .font(Theme.caption).foregroundStyle(Theme.muted)
            }
            SpotCards(hero: todaySpot.hero, villainHand: todaySpot.villainHand, villainName: todaySpot.villain?.name, board: todaySpot.board)
            Button { router.open(.dailyDrill) } label: { Text("Answer today's spot") }
                .buttonStyle(.primary)
                .accessibilityIdentifier("daily-drill-button")
        }
        .panel()
    }
}

extension DrillKind {
    var symbol: String {
        switch self {
        case .equityQuiz: "percent"
        case .potOdds: "scalemass"
        case .rangeTrainer: "square.grid.3x3"
        }
    }
    var blurb: String {
        switch self {
        case .equityQuiz: "Guess your equity, then see the exact answer."
        case .potOdds: "Facing a bet: call or fold?"
        case .rangeTrainer: "Paint push/fold ranges against the Nash chart."
        }
    }
}
