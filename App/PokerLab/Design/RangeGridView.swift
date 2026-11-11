import SwiftUI
import PokerCore

/// The 13x13 starting-hand grid. Read-only (shaded by frequency) or editable with tap and
/// drag-to-paint. Every cell is a VoiceOver element ("Ace king suited, in range") with a toggle
/// action, and an "In range" rotor jumps between selected hands.
struct RangeGridView: View {
    /// Frequency 0...1 per HandClass.index.
    let values: [Double]
    var editable = false
    var tint: Color = Theme.hero
    /// Optional per-cell outline (e.g. to mark mistakes after grading).
    var outline: (HandClass) -> Color? = { _ in nil }
    var onChange: ((HandClass, Bool) -> Void)?

    @State private var paintValue: Bool?
    @State private var lastPainted: HandClass?
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        GeometryReader { geo in
            let side = geo.size.width / 13
            ZStack(alignment: .topLeading) {
                ForEach(HandClass.all, id: \.self) { hc in
                    cell(hc, side: side)
                        .position(x: (CGFloat(hc.column) + 0.5) * side, y: (CGFloat(hc.row) + 0.5) * side)
                }
            }
            .contentShape(Rectangle())
            .gesture(editable ? paintGesture(side: side) : nil)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .contain)
        .accessibilityRotor("In range") {
            ForEach(HandClass.all.filter { values[$0.index] >= 0.5 }, id: \.self) { hc in
                AccessibilityRotorEntry(hc.spokenName, id: hc)
            }
        }
    }

    private func cell(_ hc: HandClass, side: CGFloat) -> some View {
        let v = values[hc.index]
        return ZStack {
            Rectangle().fill(Theme.subtle)
            Rectangle().fill(tint.opacity(0.15 + 0.85 * v)).opacity(v > 0.001 ? 1 : 0)
            if let color = outline(hc) {
                Rectangle().strokeBorder(color, lineWidth: 2)
            }
            if !typeSize.isAccessibilitySize {
                Text(hc.description.replacingOccurrences(of: "o", with: ""))
                    .font(.system(size: side * 0.32, weight: .medium))
                    .minimumScaleFactor(0.5)
                    .foregroundStyle(v > 0.5 ? Theme.onInk : Theme.ink)
            }
        }
        .frame(width: side - 1, height: side - 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(hc.spokenName)
        .accessibilityValue(v >= 0.999 ? "In range" : v <= 0.001 ? "Not in range" : "\(Int((v * 100).rounded())) percent")
        .accessibilityAddTraits(editable ? .isButton : [])
        .accessibilityAction { if editable { onChange?(hc, v < 0.5) } }
        .accessibilityIdentifier("grid-\(hc)")
        .id(hc)
    }

    private func paintGesture(side: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                let col = Int(g.location.x / side), row = Int(g.location.y / side)
                guard (0..<13).contains(col), (0..<13).contains(row) else { return }
                let hc = HandClass(row: row, column: col)
                if paintValue == nil { paintValue = values[hc.index] < 0.5 }
                if hc != lastPainted, let v = paintValue {
                    lastPainted = hc
                    onChange?(hc, v)
                }
            }
            .onEnded { _ in paintValue = nil; lastPainted = nil }
    }
}
