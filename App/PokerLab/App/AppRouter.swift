import SwiftUI
import PokerTraining

enum AppTab: String, Hashable, CaseIterable {
    case today, lab, train, progress
}

/// Navigation state shared by tabs, deep links (widget, App Intents) and Live Activities.
@MainActor @Observable
final class AppRouter {
    var tab: AppTab = .today
    var trainPath = NavigationPath()
    var labPath = NavigationPath()
    /// A spot waiting to be loaded by the Equity Lab (from the camera or an App Intent).
    var pendingLabSpot: LabSpot?

    /// Shows the Equity Lab root with `spot` loaded.
    func sendToLab(_ spot: LabSpot) {
        pendingLabSpot = spot
        labPath = NavigationPath()
        trainPath = NavigationPath()
        tab = .lab
    }

    enum Destination: Hashable {
        case drill(DrillKind)
        case dailyDrill
        case solver
        case camera
        case settings
    }

    func open(_ destination: Destination) {
        switch destination {
        case .drill, .dailyDrill:
            tab = .train
            trainPath = NavigationPath()
            trainPath.append(destination)
        case .solver, .camera:
            tab = .lab
            labPath = NavigationPath()
            labPath.append(destination)
        case .settings:
            tab = .today
        }
    }

    /// pokerlab://drill/potOdds, pokerlab://daily, pokerlab://solver, pokerlab://camera
    func handle(_ url: URL) {
        guard url.scheme == "pokerlab" else { return }
        switch url.host() {
        case "drill":
            if let kind = DrillKind(rawValue: url.lastPathComponent) { open(.drill(kind)) }
        case "daily": open(.dailyDrill)
        case "solver": open(.solver)
        case "camera": open(.camera)
        case "lab": tab = .lab
        default: break
        }
    }
}

struct RootView: View {
    @Environment(AppRouter.self) private var router

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.tab) {
            Tab("Today", systemImage: "sun.max", value: AppTab.today) { TodayView() }
            Tab("Lab", systemImage: "flask", value: AppTab.lab) { LabTab() }
            Tab("Train", systemImage: "target", value: AppTab.train) { TrainView() }
            Tab("Progress", systemImage: "chart.line.uptrend.xyaxis", value: AppTab.progress) { ProgressScreen() }
        }
    }
}
