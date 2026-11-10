public struct RangeParseError: Error, Equatable, Sendable, CustomStringConvertible {
    public let token: String
    public let reason: String
    public var description: String { "\"\(token)\": \(reason)" }
}

/// Parses standard range notation:
///   pairs "QQ", "QQ+", "QQ-88";   non-pairs "AK" (suited + offsuit), "AKs", "AKo";
///   "ATs+" (AT..AK suited), "A5s-A2s" (fixed high card, kicker span);
///   specific combos "AsKd";   weights "AKs:0.5";   "random" / "any" for all hands.
/// Tokens are separated by commas or whitespace.
public enum RangeParser {
    public static func parse(_ text: String) throws -> HandRange {
        let tokens = text.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
        var combos: [HandRange.Combo] = []
        for token in tokens {
            var body = token
            var weight = 1.0
            if let colon = token.firstIndex(of: ":") {
                body = String(token[..<colon])
                guard let w = Double(token[token.index(after: colon)...]), w >= 0, w <= 1 else {
                    throw RangeParseError(token: token, reason: "weight must be a number from 0 to 1")
                }
                weight = w
            }
            let hands = try expand(body, original: token)
            combos.append(contentsOf: hands.map { HandRange.Combo($0, weight: weight) })
        }
        return HandRange(combos: combos)
    }

    private enum Suitedness { case suited, offsuit, both }

    private static func classes(_ hi: Rank, _ lo: Rank, _ s: Suitedness) -> [HandClass] {
        if hi == lo { return [HandClass(hi, lo, suited: false)] }
        switch s {
        case .suited: return [HandClass(hi, lo, suited: true)]
        case .offsuit: return [HandClass(hi, lo, suited: false)]
        case .both: return [HandClass(hi, lo, suited: true), HandClass(hi, lo, suited: false)]
        }
    }

    /// Splits "AKs" into (A, K, suited). Accepts "10" for ten.
    private static func parseClassToken(_ raw: String, original: String) throws -> (Rank, Rank, Suitedness) {
        let t = raw.replacingTen()
        let chars = Array(t)
        guard chars.count == 2 || chars.count == 3,
              let a = Rank(symbol: chars[0]), let b = Rank(symbol: chars[1]) else {
            throw RangeParseError(token: original, reason: "expected a hand like AKs, QQ or T9o")
        }
        var s = Suitedness.both
        if chars.count == 3 {
            switch chars[2] {
            case "s", "S": s = .suited
            case "o", "O": s = .offsuit
            default: throw RangeParseError(token: original, reason: "suffix must be s or o")
            }
            if a == b { throw RangeParseError(token: original, reason: "pairs cannot be suited or offsuit") }
        }
        return (max(a, b), min(a, b), s)
    }

    static func expand(_ body: String, original: String) throws -> [HoleCards] {
        let lower = body.lowercased()
        if lower == "random" || lower == "any" || lower == "100%" || lower == "xxxx" {
            return HandClass.all.flatMap(\.combos)
        }
        // Specific combo: "AsKd" / "10sKd".
        let normalized = body.replacingTen()
        if normalized.count == 4, let hole = HoleCards(normalized) { return [hole] }

        if body.hasSuffix("+") {
            let (hi, lo, s) = try parseClassToken(String(body.dropLast()), original: original)
            if hi == lo {
                return Rank.allCases.filter { $0 >= hi }.flatMap { classes($0, $0, .both) }.flatMap(\.combos)
            }
            return Rank.allCases.filter { $0 >= lo && $0 < hi }.flatMap { classes(hi, $0, s) }.flatMap(\.combos)
        }
        if body.contains("-") {
            let parts = body.split(separator: "-").map(String.init)
            guard parts.count == 2 else { throw RangeParseError(token: original, reason: "a span needs two ends, like A5s-A2s") }
            let (h1, l1, s1) = try parseClassToken(parts[0], original: original)
            let (h2, l2, s2) = try parseClassToken(parts[1], original: original)
            guard s1 == s2 else { throw RangeParseError(token: original, reason: "both ends must have the same suitedness") }
            if h1 == l1 && h2 == l2 {
                let (a, b) = (min(h1, h2), max(h1, h2))
                return Rank.allCases.filter { $0 >= a && $0 <= b }.flatMap { classes($0, $0, .both) }.flatMap(\.combos)
            }
            guard h1 == h2, h1 != l1, h2 != l2 else {
                throw RangeParseError(token: original, reason: "span ends must share the high card, like A5s-A2s or 99-66")
            }
            let (a, b) = (min(l1, l2), max(l1, l2))
            return Rank.allCases.filter { $0 >= a && $0 <= b }.flatMap { classes(h1, $0, s1) }.flatMap(\.combos)
        }
        let (hi, lo, s) = try parseClassToken(body, original: original)
        return classes(hi, lo, s).flatMap(\.combos)
    }
}

extension String {
    func replacingTen() -> String {
        var out = ""
        var chars = Array(self)[...]
        while let c = chars.first {
            if c == "1", chars.dropFirst().first == "0" { out.append("T"); chars = chars.dropFirst(2) }
            else { out.append(c); chars = chars.dropFirst() }
        }
        return out
    }
}
