import Foundation
import PokerCore

/// Exact all-in preflop equity of every hand class against every other (169 x 169),
/// generated offline by `PokerTables preflop` (full enumeration of every board for every
/// canonical combo matchup) and shipped as a 114 KB resource.
public struct PreflopEquityTable: Sendable {
    /// equity[i * 169 + j] = equity of class i against class j, averaged over all
    /// non-conflicting combo pairs.
    public let equity: [Float]
    /// pairCount[i * 169 + j] = number of non-conflicting combo pairs (i, j). Symmetric.
    public let pairCount: [Int]

    public enum LoadError: Error { case missingResource, badFormat }

    public static let shared: PreflopEquityTable = {
        do { return try PreflopEquityTable() } catch { fatalError("PreflopEquity.bin missing or corrupt: \(error)") }
    }()

    public init() throws {
        guard let url = Bundle.module.url(forResource: "PreflopEquity", withExtension: "bin") else {
            throw LoadError.missingResource
        }
        try self.init(data: Data(contentsOf: url))
    }

    public init(data: Data) throws {
        let n = 169 * 169
        guard data.count == 8 + 4 * n, data.prefix(4) == Data("PLEQ".utf8) else { throw LoadError.badFormat }
        var eq = [Float](repeating: 0, count: n)
        data.withUnsafeBytes { raw in
            for i in 0..<n {
                let bits = raw.loadUnaligned(fromByteOffset: 8 + 4 * i, as: UInt32.self)
                eq[i] = Float(bitPattern: UInt32(littleEndian: bits))
            }
        }
        equity = eq
        pairCount = PreflopEquityTable.computePairCounts()
    }

    public func equity(_ a: HandClass, vs b: HandClass) -> Double { Double(equity[a.index * 169 + b.index]) }

    static func computePairCounts() -> [Int] {
        let combos = HandClass.all.map { $0.combos.map(\.mask) }
        var counts = [Int](repeating: 0, count: 169 * 169)
        for i in 0..<169 {
            for j in i..<169 {
                var n = 0
                for a in combos[i] { for b in combos[j] where a & b == 0 { n += 1 } }
                counts[i * 169 + j] = n
                counts[j * 169 + i] = n
            }
        }
        return counts
    }
}
