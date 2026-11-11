#if canImport(Metal)
import Metal
import PokerCore

/// GPU CFR+: one threadgroup per stack depth, one thread per hand class. Each thread owns its
/// class's regrets and strategy sums in registers; the two strategy vectors live in threadgroup
/// memory, and the whole iteration loop runs inside the kernel with threadgroup barriers
/// between the small-blind and big-blind half-steps. The matrices are shared by every depth
/// (the stack only scales payoffs), so many depths solve in a single dispatch.
public final class MetalCFRSolver: @unchecked Sendable {
    // Metal objects are thread-safe for these uses; the solver holds no mutable state between calls.
    public let device: MTLDevice
    let queue: MTLCommandQueue
    let pipelines: [Kernel: MTLComputePipelineState]
    let wBuffer: MTLBuffer, aBuffer: MTLBuffer, rowBuffer: MTLBuffer
    let matrices: PushFoldMatrices
    /// Test hook: caps the threadgroup width below the pipeline's limit, to exercise the
    /// narrow dispatches the iOS Simulator forces on a Mac GPU.
    var threadCap: Int?

    public enum SolverError: Error { case noDevice, commandFailed(String), unsupportedThreadgroupSize(Int) }

    /// `rowPerThread`: one thread per hand class, serial 169-term dot products (v1).
    /// `simdGroupRows`: 1,024 threads per depth; each row's dot product is split across a
    /// 32-lane SIMD group and reduced with `simd_sum` (v2, the default).
    public enum Kernel: String, CaseIterable, Sendable {
        case rowPerThread = "cfr_push_fold"
        case simdGroupRows = "cfr_push_fold_simd"
        /// Preferred threadgroup width. The real width is clamped to what the pipeline allows.
        var threadsPerGroup: Int { self == .rowPerThread ? 192 : 1024 }

        /// The threadgroup width to dispatch with on this pipeline, or nil if it cannot run.
        /// Limits vary by GPU and are much lower on the iOS Simulator, and dispatching more
        /// threads than `maxTotalThreadsPerThreadgroup` trips a Metal validation assert.
        func threadCount(for pipeline: MTLComputePipelineState, cap: Int? = nil) -> Int? {
            let limit = min(threadsPerGroup, pipeline.maxTotalThreadsPerThreadgroup, cap ?? .max)
            switch self {
            case .rowPerThread:
                // One thread per hand class: needs at least 169 threads in the group.
                return limit >= PushFoldMatrices.n ? limit : nil
            case .simdGroupRows:
                // Whole SIMD groups only; the kernel strides by the real group count.
                let width = max(1, pipeline.threadExecutionWidth)
                let threads = limit / width * width
                return threads >= width ? threads : nil
            }
        }
    }

    public init(matrices: PushFoldMatrices = .shared) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw SolverError.noDevice
        }
        let library = try device.makeLibrary(source: MetalCFRSolver.shaderSource, options: nil)
        var pipes: [Kernel: MTLComputePipelineState] = [:]
        for k in Kernel.allCases {
            guard let fn = library.makeFunction(name: k.rawValue) else { throw SolverError.noDevice }
            pipes[k] = try device.makeComputePipelineState(function: fn)
        }
        pipelines = pipes
        self.device = device
        self.queue = queue
        self.matrices = matrices
        wBuffer = device.makeBuffer(bytes: matrices.w, length: matrices.w.count * 4, options: .storageModeShared)!
        aBuffer = device.makeBuffer(bytes: matrices.a, length: matrices.a.count * 4, options: .storageModeShared)!
        rowBuffer = device.makeBuffer(bytes: matrices.rowSum, length: matrices.rowSum.count * 4, options: .storageModeShared)!
    }

    public var deviceName: String { device.name }

    /// Solves every stack depth together. GPU time is measured with command-buffer timestamps;
    /// exploitability checkpoints are computed on the CPU between dispatches and not timed.
    public func solve(stacks: [Double], iterations: Int, checkpointEvery: Int = 50,
                      kernel: Kernel = .simdGroupRows) throws -> [PushFoldSolution] {
        let s = PushFoldMatrices.stride, n = PushFoldMatrices.n
        let depthCount = stacks.count
        let floatsPerDepth = 8 * s
        var initial = [Float](repeating: 0, count: depthCount * floatsPerDepth)
        for d in 0..<depthCount {
            for i in 0..<n { initial[d * floatsPerDepth + 6 * s + i] = 0.5; initial[d * floatsPerDepth + 7 * s + i] = 0.5 }
        }
        let state = device.makeBuffer(bytes: initial, length: initial.count * 4, options: .storageModeShared)!
        let stackFloats = stacks.map(Float.init)
        let stackBuffer = device.makeBuffer(bytes: stackFloats, length: max(4, stackFloats.count * 4), options: .storageModeShared)!
        var curves = [[PushFoldSolution.Checkpoint]](repeating: [], count: depthCount)
        var gpuSeconds = 0.0
        var done = 0
        while done < iterations {
            let chunk = min(checkpointEvery, iterations - done)
            var params = (UInt32(chunk), UInt32(done))
            guard let cmd = queue.makeCommandBuffer(), let enc = cmd.makeComputeCommandEncoder() else {
                throw SolverError.commandFailed("could not create command buffer")
            }
            let pipeline = pipelines[kernel]!
            guard let threads = kernel.threadCount(for: pipeline, cap: threadCap) else {
                enc.endEncoding()
                throw SolverError.unsupportedThreadgroupSize(pipeline.maxTotalThreadsPerThreadgroup)
            }
            enc.setComputePipelineState(pipeline)
            enc.setBuffer(wBuffer, offset: 0, index: 0)
            enc.setBuffer(aBuffer, offset: 0, index: 1)
            enc.setBuffer(rowBuffer, offset: 0, index: 2)
            enc.setBuffer(stackBuffer, offset: 0, index: 3)
            enc.setBuffer(state, offset: 0, index: 4)
            enc.setBytes(&params, length: 8, index: 5)
            enc.dispatchThreadgroups(MTLSize(width: depthCount, height: 1, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: threads, height: 1, depth: 1))
            enc.endEncoding()
            cmd.commit()
            cmd.waitUntilCompleted()
            if let error = cmd.error { throw SolverError.commandFailed(error.localizedDescription) }
            gpuSeconds += cmd.gpuEndTime - cmd.gpuStartTime
            done += chunk
            let ptr = state.contents().bindMemory(to: Float.self, capacity: initial.count)
            let weight = Double(done) * Double(done + 1) / 2
            for d in 0..<depthCount {
                let base = d * floatsPerDepth
                let p = (0..<n).map { Double(ptr[base + 4 * s + $0]) / weight }
                let c = (0..<n).map { Double(ptr[base + 5 * s + $0]) / weight }
                curves[d].append(.init(iteration: done, exploitability: matrices.exploitability(push: p, call: c, stack: stacks[d])))
            }
        }
        let ptr = state.contents().bindMemory(to: Float.self, capacity: initial.count)
        let weight = Double(iterations) * Double(iterations + 1) / 2
        return (0..<depthCount).map { d in
            let base = d * floatsPerDepth
            return PushFoldSolution(stack: stacks[d],
                                    push: (0..<n).map { Double(ptr[base + 4 * s + $0]) / weight },
                                    call: (0..<n).map { Double(ptr[base + 5 * s + $0]) / weight },
                                    iterations: iterations, curve: curves[d],
                                    elapsedSeconds: gpuSeconds)
        }
    }

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    constant uint N = 169;
    constant uint P = 176;   // padded row stride

    struct Params { uint iterations; uint startIteration; };

    // State per depth, 8 * P floats: regretPush, regretFold, regretCall, regretPass,
    // sumPush, sumCall, push, call.
    kernel void cfr_push_fold(device const float *W      [[buffer(0)]],
                              device const float *A      [[buffer(1)]],
                              device const float *rowSum [[buffer(2)]],
                              device const float *stacks [[buffer(3)]],
                              device float *state        [[buffer(4)]],
                              constant Params &params    [[buffer(5)]],
                              uint tid   [[thread_index_in_threadgroup]],
                              uint depth [[threadgroup_position_in_grid]])
    {
        threadgroup float p[P];
        threadgroup float c[P];
        device float *st = state + depth * 8 * P;
        const float S = stacks[depth];
        const bool active = tid < N;
        float rp = 0, rf = 0, rc = 0, rx = 0, sp = 0, sc = 0, r = 0;
        if (active) {
            rp = st[tid]; rf = st[P + tid]; rc = st[2 * P + tid]; rx = st[3 * P + tid];
            sp = st[4 * P + tid]; sc = st[5 * P + tid];
            p[tid] = st[6 * P + tid]; c[tid] = st[7 * P + tid];
            r = rowSum[tid];
        } else if (tid < P) {
            p[tid] = 0; c[tid] = 0;
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        device const float *a = A + tid * P;
        device const float *w = W + tid * P;

        for (uint k = 0; k < params.iterations; k++) {
            const float t = float(params.startIteration + k + 1);
            float newP = 0;
            if (active) {
                float ac = 0, wc = 0;
                for (uint j = 0; j < N; j++) { float cj = c[j]; ac = fma(a[j], cj, ac); wc = fma(w[j], cj, wc); }
                float vPush = S * ac + r - wc;
                float vFold = -0.5f * r;
                float pi = p[tid];
                float v = pi * vPush + (1.0f - pi) * vFold;
                sp += t * pi;
                rp = max(rp + vPush - v, 0.0f);
                rf = max(rf + vFold - v, 0.0f);
                float sum = rp + rf;
                newP = sum > 0 ? rp / sum : 0.5f;
            }
            threadgroup_barrier(mem_flags::mem_threadgroup);
            if (active) { p[tid] = newP; }
            threadgroup_barrier(mem_flags::mem_threadgroup);
            float newC = 0;
            if (active) {
                float ap = 0, wp = 0;
                for (uint j = 0; j < N; j++) { float pj = p[j]; ap = fma(a[j], pj, ap); wp = fma(w[j], pj, wp); }
                float vCall = S * ap;
                float vFold = -wp;
                float ci = c[tid];
                float v = ci * vCall + (1.0f - ci) * vFold;
                sc += t * ci;
                rc = max(rc + vCall - v, 0.0f);
                rx = max(rx + vFold - v, 0.0f);
                float sum = rc + rx;
                newC = sum > 0 ? rc / sum : 0.5f;
            }
            threadgroup_barrier(mem_flags::mem_threadgroup);
            if (active) { c[tid] = newC; }
            threadgroup_barrier(mem_flags::mem_threadgroup);
        }
        if (active) {
            st[tid] = rp; st[P + tid] = rf; st[2 * P + tid] = rc; st[3 * P + tid] = rx;
            st[4 * P + tid] = sp; st[5 * P + tid] = sc;
            st[6 * P + tid] = p[tid]; st[7 * P + tid] = c[tid];
        }
    }

    // v2: rows are distributed over the threadgroup's SIMD groups; the lanes of a group split
    // each 169-term dot product and reduce with simd_sum. Per-class state lives in threadgroup
    // memory. Strides come from the dispatch, so any whole number of SIMD groups works.
    kernel void cfr_push_fold_simd(device const float *W      [[buffer(0)]],
                                   device const float *A      [[buffer(1)]],
                                   device const float *rowSum [[buffer(2)]],
                                   device const float *stacks [[buffer(3)]],
                                   device float *state        [[buffer(4)]],
                                   constant Params &params    [[buffer(5)]],
                                   uint tid     [[thread_index_in_threadgroup]],
                                   uint lane    [[thread_index_in_simdgroup]],
                                   uint sg      [[simdgroup_index_in_threadgroup]],
                                   uint threads [[threads_per_threadgroup]],
                                   uint groups  [[simdgroups_per_threadgroup]],
                                   uint width   [[threads_per_simdgroup]],
                                   uint depth   [[threadgroup_position_in_grid]])
    {
        threadgroup float rp[P], rf[P], rc[P], rx[P], sp[P], sc[P], p[P], c[P], next[P];
        device float *st = state + depth * 8 * P;
        const float S = stacks[depth];
        for (uint i = tid; i < P; i += threads) {
            rp[i] = st[i]; rf[i] = st[P + i]; rc[i] = st[2 * P + i]; rx[i] = st[3 * P + i];
            sp[i] = st[4 * P + i]; sc[i] = st[5 * P + i]; p[i] = st[6 * P + i]; c[i] = st[7 * P + i];
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        for (uint k = 0; k < params.iterations; k++) {
            const float t = float(params.startIteration + k + 1);
            for (uint r = sg; r < N; r += groups) {
                device const float *a = A + r * P;
                device const float *w = W + r * P;
                float ac = 0, wc = 0;
                for (uint j = lane; j < N; j += width) { float cj = c[j]; ac = fma(a[j], cj, ac); wc = fma(w[j], cj, wc); }
                ac = simd_sum(ac); wc = simd_sum(wc);
                if (lane == 0) {
                    float rs = rowSum[r];
                    float vPush = S * ac + rs - wc, vFold = -0.5f * rs;
                    float pi = p[r];
                    float v = pi * vPush + (1.0f - pi) * vFold;
                    sp[r] += t * pi;
                    float a1 = max(rp[r] + vPush - v, 0.0f), b1 = max(rf[r] + vFold - v, 0.0f);
                    rp[r] = a1; rf[r] = b1;
                    next[r] = (a1 + b1) > 0 ? a1 / (a1 + b1) : 0.5f;
                }
            }
            threadgroup_barrier(mem_flags::mem_threadgroup);
            for (uint i = tid; i < N; i += threads) p[i] = next[i];
            threadgroup_barrier(mem_flags::mem_threadgroup);
            for (uint r = sg; r < N; r += groups) {
                device const float *a = A + r * P;
                device const float *w = W + r * P;
                float ap = 0, wp = 0;
                for (uint j = lane; j < N; j += width) { float pj = p[j]; ap = fma(a[j], pj, ap); wp = fma(w[j], pj, wp); }
                ap = simd_sum(ap); wp = simd_sum(wp);
                if (lane == 0) {
                    float vCall = S * ap, vFold = -wp;
                    float ci = c[r];
                    float v = ci * vCall + (1.0f - ci) * vFold;
                    sc[r] += t * ci;
                    float a1 = max(rc[r] + vCall - v, 0.0f), b1 = max(rx[r] + vFold - v, 0.0f);
                    rc[r] = a1; rx[r] = b1;
                    next[r] = (a1 + b1) > 0 ? a1 / (a1 + b1) : 0.5f;
                }
            }
            threadgroup_barrier(mem_flags::mem_threadgroup);
            for (uint i = tid; i < N; i += threads) c[i] = next[i];
            threadgroup_barrier(mem_flags::mem_threadgroup);
        }
        for (uint i = tid; i < N; i += threads) {
            st[i] = rp[i]; st[P + i] = rf[i]; st[2 * P + i] = rc[i]; st[3 * P + i] = rx[i];
            st[4 * P + i] = sp[i]; st[5 * P + i] = sc[i]; st[6 * P + i] = p[i]; st[7 * P + i] = c[i];
        }
    }
    """
}
#endif
