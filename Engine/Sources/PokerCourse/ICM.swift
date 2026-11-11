/// Independent Chip Model (Malmuth-Harville): a player finishes first with probability
/// proportional to their stack; given that, the rest of the field is ranked the same way.
/// Players with zero chips are ranked last (they have already busted).
public enum ICM {
    /// Prize equity of each player. `payouts[k]` is the prize for finishing k+1-th.
    public static func equities(stacks: [Double], payouts: [Double]) -> [Double] {
        precondition(stacks.allSatisfy { $0 >= 0 })
        var result = [Double](repeating: 0, count: stacks.count)
        let alive = stacks.indices.filter { stacks[$0] > 0 }
        let busted = stacks.indices.filter { stacks[$0] == 0 }
        // Busted players take the last places (split evenly if several bust at once).
        let bustedPlaces = (alive.count..<stacks.count).map { $0 < payouts.count ? payouts[$0] : 0 }
        let bustedShare = busted.isEmpty ? 0 : bustedPlaces.reduce(0, +) / Double(busted.count)
        for b in busted { result[b] = bustedShare }

        var memo: [Int: [Double]] = [:]
        // Expected prize per player when the players in `mask` compete for places from `place` on.
        func solve(_ mask: Int, _ place: Int) -> [Double] {
            if let m = memo[mask] { return m }
            var eq = [Double](repeating: 0, count: stacks.count)
            let members = alive.filter { mask & (1 << $0) != 0 }
            let total = members.reduce(0) { $0 + stacks[$1] }
            guard place < payouts.count, total > 0 else { memo[mask] = eq; return eq }
            for i in members {
                let p = stacks[i] / total
                eq[i] += p * payouts[place]
                let rest = solve(mask & ~(1 << i), place + 1)
                for j in members where j != i { eq[j] += p * rest[j] }
            }
            memo[mask] = eq
            return eq
        }
        let full = alive.reduce(0) { $0 | (1 << $1) }
        let eq = solve(full, 0)
        for i in alive { result[i] = eq[i] }
        return result
    }
}
