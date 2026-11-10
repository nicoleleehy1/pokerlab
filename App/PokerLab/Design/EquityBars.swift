import SwiftUI

/// Hero/villain equity as one split bar plus big rolling numbers.
struct EquityBars: View {
    let hero: Double
    let villain: Double
    var heroLabel = "You"
    var villainLabel = "Villain"
    var standardError: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                number(hero, label: heroLabel, color: Theme.hero)
                Spacer()
                number(villain, label: villainLabel, color: Theme.villain, trailing: true)
            }
            GeometryReader { geo in
                HStack(spacing: 2) {
                    Capsule().fill(Theme.hero).frame(width: max(4, geo.size.width * hero))
                    Capsule().fill(Theme.villain)
                }
            }
            .frame(height: 12)
            .accessibilityHidden(true)
            if let se = standardError {
                Text(se == 0 ? "Exact" : "± \(Theme.percent(1.96 * se, digits: 2)) (95% interval)")
                    .font(Theme.smallNumber)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
        }
        .motionAware(hero)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(heroLabel) \(Theme.percent(hero)), \(villainLabel) \(Theme.percent(villain))")
    }

    private func number(_ x: Double, label: String, color: Color, trailing: Bool = false) -> some View {
        VStack(alignment: trailing ? .trailing : .leading, spacing: 2) {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            Text(Theme.percent(x))
                .font(Theme.bigNumber)
                .foregroundStyle(color)
                .contentTransition(.numericText(value: x))
        }
    }
}
