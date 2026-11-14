#if canImport(Metal)
import Foundation
import Metal

/// Metal backend for `RiverSolver`.
///
/// Each traversal runs in three passes instead of one recursion: a forward pass on the CPU
/// computes every node's reach vectors from the current strategies, one GPU dispatch then
/// evaluates every terminal node at once (one thread per (terminal, hand), looping over the
/// opponent's hands with card-removal checks), and a backward pass on the CPU folds the values
/// up the tree and applies the same DCFR updates as the CPU solver.
///
/// The GPU does O(n²) work per terminal where the CPU's sort-and-sweep does O(n), so this is a
/// measurement of where (and whether) the GPU pays off rather than the default path.
public final class MetalRiverBackend: @unchecked Sendable {
    let solver: RiverSolver
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLComputePipelineState
    public let terminals: [Int]
    let terminalSlot: [Int: Int]
    // Per player p (as the hero): hand data buffers.
    var heroCards: [MTLBuffer] = [], heroStrength: [MTLBuffer] = []
    var oppCards: [MTLBuffer] = [], oppStrength: [MTLBuffer] = []
    var reachBuffer: [MTLBuffer] = [], outBuffer: [MTLBuffer] = [], termBuffer: [MTLBuffer] = []
    public private(set) var gpuSeconds = 0.0

    public enum BackendError: Error { case noDevice, compile(String) }

    public init(solver: RiverSolver) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw BackendError.noDevice }
        self.solver = solver; self.device = device; self.queue = queue
        do {
            let library = try device.makeLibrary(source: Self.source, options: nil)
            pipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "river_terminals")!)
        } catch { throw BackendError.compile("\(error)") }
        terminals = solver.nodes.indices.filter { if case .decision = solver.nodes[$0].kind { false } else { true } }
        terminalSlot = Dictionary(uniqueKeysWithValues: terminals.enumerated().map { ($1, $0) })
        for p in 0..<2 {
            let hero = solver.sides[p], opp = solver.sides[1 - p]
            let hc: [UInt32] = hero.reps.flatMap { [UInt32(hero.cards[$0].0), UInt32(hero.cards[$0].1)] }
            let hs: [UInt32] = hero.reps.map { UInt32(hero.strength[$0]) }
            let oc: [UInt32] = (0..<opp.count).flatMap { [UInt32(opp.cards[$0].0), UInt32(opp.cards[$0].1)] }
            let os: [UInt32] = opp.strength.map(UInt32.init)
            heroCards.append(device.makeBuffer(bytes: hc, length: hc.count * 4, options: .storageModeShared)!)
            heroStrength.append(device.makeBuffer(bytes: hs, length: hs.count * 4, options: .storageModeShared)!)
            oppCards.append(device.makeBuffer(bytes: oc, length: oc.count * 4, options: .storageModeShared)!)
            oppStrength.append(device.makeBuffer(bytes: os, length: os.count * 4, options: .storageModeShared)!)
            reachBuffer.append(device.makeBuffer(length: max(4, terminals.count * opp.count * 4), options: .storageModeShared)!)
            outBuffer.append(device.makeBuffer(length: max(4, terminals.count * hero.canonCount * 4), options: .storageModeShared)!)
            // Per terminal: kind (0 fold, 1 showdown) and the payoff multiplier for this hero.
            var terms: [Float] = []
            let half = solver.spot.pot / 2
            for t in terminals {
                let node = solver.nodes[t]
                switch node.kind {
                case .fold(let folder):
                    let paid = Float(half + (folder == 0 ? node.contributions.0 : node.contributions.1))
                    terms += [0, folder == p ? -paid : paid]
                default:
                    terms += [1, Float(half + node.contributions.0)]
                }
            }
            termBuffer.append(device.makeBuffer(bytes: terms, length: max(8, terms.count * 4), options: .storageModeShared)!)
        }
    }

    public var deviceName: String { device.name }

    /// Runs `count` DCFR iterations on `solver` using the GPU for terminal values.
    public func iterate(_ count: Int) {
        for _ in 0..<count {
            solver.iteration += 1
            let t = Double(solver.iteration)
            let ta = pow(t, RiverSolver.alpha), tb = pow(t, RiverSolver.beta)
            let pos = Float(ta / (ta + 1)), neg = Float(tb / (tb + 1)), d = Float(pow(t / (t + 1), RiverSolver.gamma))
            for p in 0..<2 { traverse(p, pos, neg, d) }
        }
    }

    private func traverse(_ p: Int, _ pos: Float, _ neg: Float, _ d: Float) {
        let nodes = solver.nodes
        // Forward: reach vectors (canonical) at every node. Parents precede children in `nodes`.
        var selfReach = [[Float]](repeating: [], count: nodes.count)
        var oppReach = [[Float]](repeating: [], count: nodes.count)
        var sigmas = [[Float]](repeating: [], count: nodes.count)
        selfReach[0] = solver.canonicalWeights(p); oppReach[0] = solver.canonicalWeights(1 - p)
        for n in nodes.indices {
            guard case .decision(let actor) = nodes[n].kind else { continue }
            let sigma = solver.currentStrategy(nodes[n], player: actor)
            sigmas[n] = sigma
            let np = solver.sides[actor].padded
            for (a, child) in nodes[n].children.enumerated() {
                var s = selfReach[n], o = oppReach[n]
                if actor == p { for h in 0..<np { s[h] *= sigma[a * np + h] } }
                else { for h in 0..<np { o[h] *= sigma[a * np + h] } }
                selfReach[child] = s; oppReach[child] = o
            }
        }
        // Terminals on the GPU.
        let opp = solver.sides[1 - p], hero = solver.sides[p]
        let reachPtr = reachBuffer[p].contents().bindMemory(to: Float.self, capacity: terminals.count * opp.count)
        for (slot, t) in terminals.enumerated() {
            let full = solver.expand(oppReach[t], side: 1 - p)
            for j in 0..<opp.count { reachPtr[slot * opp.count + j] = full[j] }
        }
        var dims = (UInt32(hero.canonCount), UInt32(opp.count), UInt32(terminals.count))
        let cmd = queue.makeCommandBuffer()!, enc = cmd.makeComputeCommandEncoder()!
        enc.setComputePipelineState(pipeline)
        enc.setBuffer(reachBuffer[p], offset: 0, index: 0)
        enc.setBuffer(heroCards[p], offset: 0, index: 1)
        enc.setBuffer(heroStrength[p], offset: 0, index: 2)
        enc.setBuffer(oppCards[p], offset: 0, index: 3)
        enc.setBuffer(oppStrength[p], offset: 0, index: 4)
        enc.setBuffer(termBuffer[p], offset: 0, index: 5)
        enc.setBytes(&dims, length: 12, index: 6)
        enc.setBuffer(outBuffer[p], offset: 0, index: 7)
        let width = min(pipeline.maxTotalThreadsPerThreadgroup, 256)
        enc.dispatchThreads(MTLSize(width: hero.canonCount, height: terminals.count, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        gpuSeconds += cmd.gpuEndTime - cmd.gpuStartTime
        let outPtr = outBuffer[p].contents().bindMemory(to: Float.self, capacity: terminals.count * hero.canonCount)

        // Backward: values and DCFR updates, children before parents.
        var values = [[Float]](repeating: [], count: nodes.count)
        for (slot, t) in terminals.enumerated() {
            var v = [Float](repeating: 0, count: hero.padded)
            for h in 0..<hero.canonCount { v[h] = outPtr[slot * hero.canonCount + h] }
            values[t] = v
        }
        for n in nodes.indices.reversed() {
            guard case .decision(let actor) = nodes[n].kind else { continue }
            let node = nodes[n], k = node.actions.count, np = solver.sides[actor].padded
            let sigma = sigmas[n]
            var value = [Float](repeating: 0, count: hero.padded)
            if actor != p {
                for child in node.children { let v = values[child]; for h in 0..<value.count { value[h] += v[h] } }
            } else {
                for (a, child) in node.children.enumerated() {
                    let v = values[child]
                    for h in 0..<np { value[h] += sigma[a * np + h] * v[h] }
                }
                for a in 0..<k {
                    let v = values[node.children[a]]
                    for h in 0..<np {
                        let i = node.offset + a * np + h
                        let r = solver.regrets[i]
                        solver.regrets[i] = r * (r > 0 ? pos : neg) + v[h] - value[h]
                        solver.strategySum[i] = (solver.strategySum[i] + selfReach[n][h] * sigma[a * np + h]) * d
                    }
                }
            }
            values[n] = value
        }
    }

    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    // One thread per (hero hand, terminal): sums the opponent's reach over compatible hands,
    // signed by the showdown result (or just summed at a fold), times the payoff.
    kernel void river_terminals(device const float *oppReach   [[buffer(0)]],
                                device const uint2 *heroCards  [[buffer(1)]],
                                device const uint  *heroStr    [[buffer(2)]],
                                device const uint2 *oppCards   [[buffer(3)]],
                                device const uint  *oppStr     [[buffer(4)]],
                                device const float2 *terms     [[buffer(5)]],
                                constant uint3 &dims           [[buffer(6)]],
                                device float *out              [[buffer(7)]],
                                uint2 gid [[thread_position_in_grid]])
    {
        const uint nh = dims.x, no = dims.y, nt = dims.z;
        if (gid.x >= nh || gid.y >= nt) return;
        const uint2 hc = heroCards[gid.x];
        const uint hs = heroStr[gid.x];
        const float2 term = terms[gid.y];
        device const float *reach = oppReach + gid.y * no;
        float acc = 0;
        for (uint j = 0; j < no; j++) {
            const float r = reach[j];
            if (r == 0) continue;
            const uint2 oc = oppCards[j];
            if (oc.x == hc.x || oc.x == hc.y || oc.y == hc.x || oc.y == hc.y) continue;
            if (term.x == 0) { acc += r; }
            else { const uint os = oppStr[j]; acc += hs > os ? r : (hs < os ? -r : 0.0f); }
        }
        out[gid.y * nh + gid.x] = acc * term.y;
    }
    """
}
#endif
