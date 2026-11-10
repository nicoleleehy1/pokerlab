#if canImport(ActivityKit)
import ActivityKit
import WidgetKit
import SwiftUI

/// Lock Screen and Dynamic Island presentation of a running drill session.
struct DrillLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DrillActivityAttributes.self) { context in
            LockScreenView(context: context)
                .padding()
                .activityBackgroundTint(Color(.systemBackground).opacity(0.8))
                .widgetURL(URL(string: "pokerlab://lab"))
        } dynamicIsland: { context in
            let s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.drillName, systemImage: "target").font(.caption.weight(.semibold))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Label("\(s.streak)", systemImage: "flame.fill").foregroundStyle(.orange).font(.caption.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        stat("Answered", "\(s.answered)/10")
                        stat("Correct", "\(s.correct)")
                        stat("Points", "\(s.points)")
                    }
                }
            } compactLeading: {
                Image(systemName: "target").foregroundStyle(.tint)
            } compactTrailing: {
                Text("\(s.correct)/\(s.answered)").font(.caption.monospacedDigit())
            } minimal: {
                Text("\(s.correct)").font(.caption.monospacedDigit())
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack {
            Text(value).font(.system(.title3, design: .rounded, weight: .semibold).monospacedDigit())
                .contentTransition(.numericText())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

private struct LockScreenView: View {
    let context: ActivityViewContext<DrillActivityAttributes>

    var body: some View {
        let s = context.state
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(context.attributes.drillName).font(.headline)
                Text("Started \(context.attributes.startedAt, style: .relative) ago").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            ProgressView(value: Double(min(s.answered, 10)), total: 10) {
                EmptyView()
            } currentValueLabel: {
                Text("\(s.answered)/10").font(.caption.monospacedDigit())
            }
            .progressViewStyle(.circular)
            .accessibilityLabel("\(s.answered) of 10 answered")
            VStack(alignment: .trailing, spacing: 2) {
                Label("\(s.streak)", systemImage: "flame.fill").foregroundStyle(.orange)
                Text("\(s.points) pts").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .font(.subheadline.monospacedDigit())
        }
    }
}
#endif
