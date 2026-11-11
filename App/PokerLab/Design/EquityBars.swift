import SwiftUI

/// Hero/villain equity as big tabular numbers over one split bar.
struct EquityBars: View {
    let hero: Double
    let villain: Double
    var heroLabel = "You"
    var villainLabel = "Villain"
    var standardError: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                number(hero, label: heroLabel, color: Theme.ink)
                Spacer()
                number(villain, label: villainLabel, color: Theme.muted, trailing: true)
            }
            SplitBar(win: hero, tie: max(0, 1 - hero - villain))
            if let se = standardError {
                Text(se == 0 ? "Exact" : "± \(Theme.percent(1.96 * se, digits: 2)) (95% interval)")
                    .font(Theme.smallNumber)
                    .foregroundStyle(Theme.muted)
                    .contentTransition(.numericText())
            }
        }
        .motionAware(hero)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(heroLabel) \(Theme.percent(hero)), \(villainLabel) \(Theme.percent(villain))")
    }

    private func number(_ x: Double, label: String, color: Color, trailing: Bool = false) -> some View {
        VStack(alignment: trailing ? .trailing : .leading, spacing: 2) {
            Text(label).font(Theme.caption).foregroundStyle(Theme.muted)
            Text(Theme.percent(x))
                .font(Theme.bigNumber)
                .tracking(-0.5)
                .foregroundStyle(color)
                .contentTransition(.numericText(value: x))
        }
    }
}

/// 8 pt win / tie / lose bar with 2 pt gaps.
struct SplitBar: View {
    let win: Double
    var tie: Double = 0

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width - 4
            HStack(spacing: 2) {
                Rectangle().fill(Theme.ink).frame(width: max(0, w * win))
                Rectangle().fill(Theme.strongBorder).frame(width: max(0, w * tie))
                Rectangle().fill(Theme.border)
            }
        }
        .frame(height: 8)
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }
}
