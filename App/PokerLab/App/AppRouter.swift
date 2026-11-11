import SwiftUI
import PokerTraining

enum AppTab: String, Hashable, CaseIterable {
    case learn, lab, practice, profile
}

/// Navigation state shared by tabs, deep links (widget, App Intents) and Live Activities.
@MainActor @Observable
final class AppRouter {
    /// One router for the app's scene and its App Intents.
    static let shared = AppRouter()

    var tab: AppTab = .learn
    var practicePath = NavigationPath()
    var labPath = NavigationPath()
    /// A spot waiting to be loaded by the Equity Lab (from the camera or an App Intent).
    var pendingLabSpot: LabSpot?

    /// Shows the Equity Lab root with `spot` loaded.
    func sendToLab(_ spot: LabSpot) {
        pendingLabSpot = spot
        labPath = NavigationPath()
        practicePath = NavigationPath()
        tab = .lab
    }

    enum Destination: Hashable {
        case drill(DrillKind)
        case dailyDrill
        case solver
        case toyGames
        case riverSolver
        case camera
        case settings
    }

    func open(_ destination: Destination) {
        switch destination {
        case .drill, .dailyDrill:
            tab = .practice
            practicePath = NavigationPath()
            practicePath.append(destination)
        case .solver, .camera, .toyGames, .riverSolver:
            tab = .lab
            labPath = NavigationPath()
            labPath.append(destination)
        case .settings:
            tab = .profile
        }
    }

    /// pokerlab://drill/potOdds, pokerlab://daily, pokerlab://solver, pokerlab://camera, pokerlab://learn|practice|profile
    func handle(_ url: URL) {
        guard url.scheme == "pokerlab" else { return }
        switch url.host() {
        case "drill":
            if let kind = DrillKind(rawValue: url.lastPathComponent) { open(.drill(kind)) }
        case "daily": open(.dailyDrill)
        case "solver": open(.solver)
        case "toys": open(.toyGames)
        case "river": open(.riverSolver)
        case "camera": open(.camera)
        case "lab": tab = .lab
        case "learn": tab = .learn
        case "practice": tab = .practice
        case "profile": tab = .profile
        default: break
        }
    }
}

struct RootView: View {
    @Environment(AppRouter.self) private var router

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.tab) {
            Tab(value: AppTab.learn) { LearnView() } label: { tabLabel("Learn", "book") }
            Tab(value: AppTab.lab) { LabTab() } label: { tabLabel("Lab", "flask") }
            Tab(value: AppTab.practice) { PracticeView() } label: { tabLabel("Practice", "target") }
            Tab(value: AppTab.profile) { ProfileView() } label: { tabLabel("Profile", "person") }
        }
        .tint(Theme.ink)
    }

    /// Line icons only: the tab bar otherwise switches to filled symbol variants.
    private func tabLabel(_ title: String, _ symbol: String) -> some View {
        Label(title, systemImage: symbol).environment(\.symbolVariants, .none)
    }
}

/// Tab bar: white (or near-black) background, a zinc-100 hairline on top, zinc-400 inactive items.
@MainActor enum TabBarAppearance {
    static func apply() {
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(Theme.background)
        appearance.shadowColor = UIColor(Theme.subtle)
        for layout in [appearance.stackedLayoutAppearance, appearance.inlineLayoutAppearance, appearance.compactInlineLayoutAppearance] {
            layout.normal.iconColor = UIColor(Theme.faint)
            layout.normal.titleTextAttributes = [.foregroundColor: UIColor(Theme.faint)]
            layout.selected.iconColor = UIColor(Theme.ink)
            layout.selected.titleTextAttributes = [.foregroundColor: UIColor(Theme.ink)]
        }
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }
}
