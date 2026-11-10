import SwiftUI
import Charts
import PokerCore
import PokerSolver

/// Heads-up push/fold Nash charts solved live with CFR+, plus the exploitability curve that
/// shows the solver converging.
struct SolverView: View {
    enum Role: String, CaseIterable, Identifiable { case shove = "SB shove", call = "BB call"; var id: Self { self } }
    enum Backend: String, CaseIterable, Identifiable { case cpu = "CPU (SIMD)", gpu = "GPU (Metal)"; var id: Self { self } }

    @State private var stack = 10.0
    @State private var role = Role.shove
    @State private var backend = Backend.cpu
    @State private var solution: PushFoldSolution?
    @State private var solving = false
    @State private var errorText: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                controls
                if let s = solution {
                    chartPanel(s)
                    exploitabilityPanel(s)
                } else {
                    ProgressView("Solving").padding(40)
                }
                Text("Heads-up, blinds 0.5/1 bb, no ante. Equities are exact (every board enumerated) for every pair of hand classes; CFR+ runs on this device.")
                    .font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Push/Fold Solver")
        .task(id: "\(stack)-\(backend)") { await solve() }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Effective stack").font(.headline)
                Spacer()
                Text("\(Int(stack)) bb").font(Theme.mediumNumber).contentTransition(.numericText(value: stack))
            }
            Slider(value: $stack, in: 2...25, step: 1) { Text("Effective stack") }
                .accessibilityValue("\(Int(stack)) big blinds")
            Picker("Chart", selection: $role) { ForEach(Role.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented)
            Picker("Backend", selection: $backend) { ForEach(Backend.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented)
            if let errorText { Text(errorText).font(.footnote).foregroundStyle(.red) }
        }
        .panel()
        .motionAware(stack)
    }

    private func chartPanel(_ s: PushFoldSolution) -> some View {
        let freq = role == .shove ? s.push : s.call
        let fraction = role == .shove ? s.pushFraction : s.callFraction
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(role == .shove ? "Shoving range" : "Calling range").font(.headline)
                Spacer()
                Text(Theme.percent(fraction)).font(Theme.mediumNumber).foregroundStyle(Theme.hero)
                    .contentTransition(.numericText(value: fraction))
            }
            RangeGridView(values: freq)
                .accessibilityLabel("\(role.rawValue) chart at \(Int(s.stack)) big blinds")
            HStack(spacing: 6) {
                Rectangle().fill(Theme.hero).frame(width: 14, height: 14)
                Text("Always").font(.caption)
                Rectangle().fill(Theme.hero.opacity(0.5)).frame(width: 14, height: 14)
                Text("Mixed").font(.caption)
                Rectangle().fill(Color(.tertiarySystemFill)).frame(width: 14, height: 14)
                Text("Fold").font(.caption)
            }
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
        }
        .panel()
    }

    private func exploitabilityPanel(_ s: PushFoldSolution) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Convergence").font(.headline)
            Text("Exploitability of the average strategy (how much a perfect opponent could win, in milli-big-blinds per hand). Zero means Nash.")
                .font(.footnote).foregroundStyle(.secondary)
            Chart(s.curve.filter { $0.exploitability > 0 }, id: \.iteration) { c in
                LineMark(x: .value("Iteration", c.iteration), y: .value("mbb/hand", c.exploitability))
                    .foregroundStyle(Theme.hero)
            }
            .chartYScale(type: .log)
            .chartYAxis { AxisMarks(values: [0.001, 0.01, 0.1, 1, 10, 100, 1000]) }
            .frame(height: 180)
            .accessibilityLabel("Exploitability chart")
            .accessibilityValue("Falls to \(String(format: "%.4f", s.exploitability)) milli big blinds per hand after \(s.iterations) iterations")
            HStack(spacing: 20) {
                stat("Iterations", "\(s.iterations)")
                stat("Solve time", "\(Int((s.elapsedSeconds * 1000).rounded())) ms")
                stat("Final", String(format: "%.4f mbb", s.exploitability))
            }
        }
        .panel()
    }

    private func stat(_ l: String, _ v: String) -> some View {
        VStack(alignment: .leading) {
            Text(l).font(.caption).foregroundStyle(.secondary)
            Text(v).font(Theme.smallNumber)
        }
        .accessibilityElement(children: .combine)
    }

    private func solve() async {
        solving = true
        defer { solving = false }
        let stack = self.stack
        let backend = self.backend
        let result: PushFoldSolution? = await Task.detached(priority: .userInitiated) {
            switch backend {
            case .cpu:
                return CFRPlusSolver().solve(stack: stack, iterations: 1000, checkpointEvery: 10)
            case .gpu:
                guard let gpu = try? MetalCFRSolver() else { return nil }
                return try? gpu.solve(stacks: [stack], iterations: 1000, checkpointEvery: 10).first
            }
        }.value
        if Task.isCancelled { return }
        if let result { solution = result; errorText = nil } else { errorText = "Metal is not available on this device." }
    }
}
