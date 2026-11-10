import SwiftUI
import SwiftData

enum AppConfig {
    /// TODO(Nicole): set to your CloudKit container (e.g. "iCloud.com.yourname.PokerLab") after
    /// creating it in the developer portal and adding it to PokerLab.entitlements. While nil,
    /// SwiftData stores everything locally and Settings shows sync as off.
    static let cloudKitContainerID: String? = nil

    static var isUITesting: Bool { ProcessInfo.processInfo.arguments.contains("-uiTesting") }
}

@main
struct PokerLabApp: App {
    @State private var router = AppRouter()
    let container: ModelContainer

    init() {
        let schema = Schema(PokerLabSchema.models)
        let config: ModelConfiguration
        if AppConfig.isUITesting {
            config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        } else if let id = AppConfig.cloudKitContainerID {
            config = ModelConfiguration(schema: schema, cloudKitDatabase: .private(id))
        } else {
            config = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
        }
        do {
            container = try ModelContainer(for: schema, configurations: [config])
        } catch {
            // A store that cannot be opened should not brick the app: fall back to memory.
            container = try! ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(router)
                .onOpenURL { router.handle($0) }
        }
        .modelContainer(container)
    }
}
