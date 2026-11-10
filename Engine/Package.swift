// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PokerEngine",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "PokerCore", targets: ["PokerCore"]),
        .library(name: "PokerSolver", targets: ["PokerSolver"]),
        .library(name: "PokerTraining", targets: ["PokerTraining"]),
    ],
    targets: [
        // Pure engine: cards, evaluator, equity, ranges. No UI, no persistence, no Foundation.
        .target(name: "PokerCore"),
        // CFR+ push/fold solver (CPU scalar, SIMD and Metal backends) and its exact equity table.
        .target(name: "PokerSolver", dependencies: ["PokerCore"], resources: [.copy("Resources/PreflopEquity.bin")]),
        // Drill generators, scoring and spaced repetition.
        .target(name: "PokerTraining", dependencies: ["PokerCore", "PokerSolver"]),
        .executableTarget(name: "PokerBench", dependencies: ["PokerCore", "PokerSolver"]),
        // Offline generators for the shipped tables (hash offsets, preflop equity matrix).
        .executableTarget(name: "PokerTables", dependencies: ["PokerCore"]),
        .testTarget(name: "PokerCoreTests", dependencies: ["PokerCore"]),
        .testTarget(name: "PokerSolverTests", dependencies: ["PokerSolver"]),
        .testTarget(name: "PokerTrainingTests", dependencies: ["PokerTraining"]),
    ],
    swiftLanguageModes: [.v6]
)
