/// SplitMix64: used to expand one seed into independent generator states.
public struct SplitMix64: RandomNumberGenerator, Sendable {
    public var state: UInt64
    @inlinable public init(seed: UInt64) { state = seed }
    @inlinable public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z &>> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z &>> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z &>> 31)
    }
}

/// xoshiro256** (Blackman & Vigna). Fast, small state, reproducible: every parallel
/// Monte Carlo worker owns one, seeded from SplitMix64, so there is no shared RNG state.
public struct Xoshiro256: RandomNumberGenerator, Sendable {
    @usableFromInline var s0, s1, s2, s3: UInt64

    public init(seed: UInt64) {
        var sm = SplitMix64(seed: seed)
        s0 = sm.next(); s1 = sm.next(); s2 = sm.next(); s3 = sm.next()
    }

    /// Seed for stream `index` of a parent seed (one stream per worker task).
    public init(seed: UInt64, stream index: Int) {
        var sm = SplitMix64(seed: seed ^ (UInt64(truncatingIfNeeded: index) &* 0xD134_2543_DE82_EF95))
        _ = sm.next()
        self.init(seed: sm.next())
    }

    @inlinable public mutating func next() -> UInt64 {
        let result = ((s1 &* 5) <<< 7) &* 9
        let t = s1 &<< 17
        s2 ^= s0; s3 ^= s1; s1 ^= s2; s0 ^= s3
        s2 ^= t
        s3 = s3 <<< 45
        return result
    }

    /// Uniform integer in 0..<bound via Lemire's multiply-shift (bias < 2^-32 for small bounds,
    /// which is far below Monte Carlo noise; avoids a division in the hot loop).
    @inlinable public mutating func next(below bound: UInt64) -> UInt64 {
        ((next() &>> 32) &* bound) &>> 32
    }

    /// Uniform Double in [0, 1).
    @inlinable public mutating func nextUnit() -> Double {
        Double(next() >> 11) * 0x1.0p-53
    }
}

infix operator <<< : BitwiseShiftPrecedence
@inlinable func <<< (x: UInt64, k: UInt64) -> UInt64 { (x &<< k) | (x &>> (64 &- k)) }
