import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

/// Starts, updates and ends the drill-session Live Activity. No-ops when Live Activities are
/// disabled or unavailable (simulators without support, the user turned them off, UI tests).
@MainActor
enum DrillLiveActivity {
    #if canImport(ActivityKit)
    /// Only the id is kept: `Activity` is not Sendable, so each update looks it up again
    /// inside a detached task instead of sending the instance across isolation domains.
    private static var currentID: String?
    #endif

    static func start(drillName: String) {
        #if canImport(ActivityKit)
        guard !AppConfig.isUITesting, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attributes = DrillActivityAttributes(drillName: drillName, startedAt: .now)
        let state = DrillActivityAttributes.ContentState(answered: 0, correct: 0, streak: 0, points: 0)
        currentID = (try? Activity.request(attributes: attributes, content: .init(state: state, staleDate: nil)))?.id
        #endif
    }

    static func update(answered: Int, correct: Int, streak: Int, points: Int) {
        #if canImport(ActivityKit)
        guard let id = currentID else { return }
        let state = DrillActivityAttributes.ContentState(answered: answered, correct: correct, streak: streak, points: points)
        Task.detached {
            for activity in Activity<DrillActivityAttributes>.activities where activity.id == id {
                await activity.update(.init(state: state, staleDate: nil))
            }
        }
        #endif
    }

    static func end(answered: Int, correct: Int, streak: Int, points: Int) {
        #if canImport(ActivityKit)
        guard let id = currentID else { return }
        currentID = nil
        let state = DrillActivityAttributes.ContentState(answered: answered, correct: correct, streak: streak, points: points)
        Task.detached {
            for activity in Activity<DrillActivityAttributes>.activities where activity.id == id {
                await activity.end(.init(state: state, staleDate: nil), dismissalPolicy: .after(.now + 60 * 5))
            }
        }
        #endif
    }
}
