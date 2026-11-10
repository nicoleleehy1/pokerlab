// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PokerEngine",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "PokerCore", targets: ["PokerCore"]),
    ],
    targets: [
        // Pure engine: cards, evaluator, equity, ranges. No UI, no persistence, no Foundation.
        .target(name: "PokerCore"),
        .executableTarget(name: "PokerBench", dependencies: ["PokerCore"]),
        // Offline generators for the shipped tables (hash offsets, preflop equity matrix).
        .executableTarget(name: "PokerTables", dependencies: ["PokerCore"]),
        .testTarget(name: "PokerCoreTests", dependencies: ["PokerCore"]),
    ],
    swiftLanguageModes: [.v6]
)
