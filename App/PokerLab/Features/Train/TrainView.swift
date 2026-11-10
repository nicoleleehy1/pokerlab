import SwiftUI
import PokerTraining

struct TrainView: View {
    @Environment(AppRouter.self) private var router

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.trainPath) {
            List {
                Section {
                    ForEach(DrillKind.allCases) { kind in
                        NavigationLink(value: AppRouter.Destination.drill(kind)) {
                            DrillRow(kind: kind)
                        }
                        .accessibilityIdentifier("drill-\(kind.rawValue)")
                    }
                } footer: {
                    Text("Each session is 10 spots. PokerLab repeats the categories you miss more often.")
                }
                Section("Reference") {
                    NavigationLink(value: AppRouter.Destination.solver) {
                        Label("Push/fold Nash charts", systemImage: "square.grid.3x3.fill")
                    }
                }
            }
            .navigationTitle("Train")
            .navigationDestination(for: AppRouter.Destination.self) { d in
                switch d {
                case .drill(let kind): DrillSessionView(kind: kind)
                case .dailyDrill: DrillSessionView(kind: .equityQuiz, isDaily: true)
                case .solver: SolverView()
                case .camera: CameraScanView()
                case .settings: SettingsView()
                }
            }
        }
    }
}

struct DrillRow: View {
    let kind: DrillKind
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: kind.symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title).font(.headline)
                Text(kind.blurb).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
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
