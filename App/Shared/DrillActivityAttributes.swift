#if canImport(ActivityKit)
import ActivityKit
import Foundation

/// Live Activity for a running drill session (Lock Screen and Dynamic Island).
struct DrillActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var answered: Int
        var correct: Int
        var streak: Int
        var points: Int
    }

    var drillName: String
    var startedAt: Date
}
#endif
