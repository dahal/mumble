import Foundation

/// Fuzzy matching between the names a meeting shows ("Sarah C.", "sarah", "sarah.chen@acme.com")
/// and the people Mumble knows.
public enum NameMatcher {
    /// Lowercased words without punctuation or diacritics; an email becomes its local-part words.
    public static func tokens(_ name: String) -> [String] {
        var value = name
        if let at = value.firstIndex(of: "@") { value = String(value[..<at]) }
        value = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        return value
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// How well two names refer to the same person, 0...1.
    ///
    /// 1.0 exact token match; 0.9 one name extends the other with initials ("Sarah C." / "Sarah Chen");
    /// 0.75 same first name only; 0 otherwise.
    public static func score(_ a: String, _ b: String) -> Double {
        let ta = tokens(a), tb = tokens(b)
        guard !ta.isEmpty, !tb.isEmpty else { return 0 }
        if ta == tb { return 1 }
        // Joined forms, e.g. "sarahchen" vs "Sarah Chen".
        if ta.joined() == tb.joined() { return 1 }
        guard ta[0] == tb[0] else { return 0 }
        let (short, long) = ta.count <= tb.count ? (ta, tb) : (tb, ta)
        var compatible = true
        for (i, token) in short.enumerated().dropFirst() {
            let other = long[i]
            if token == other { continue }
            if token.count == 1, other.hasPrefix(token) { continue }
            if other.count == 1, token.hasPrefix(other) { continue }
            compatible = false
        }
        if compatible, short.count > 1 { return 0.9 }
        return 0.75
    }

    /// Best candidate for `name` among `candidates`, if it is a confident and unambiguous match.
    /// A first-name-only match is accepted only when no other candidate shares that first name.
    public static func bestMatch<T>(for name: String, in candidates: [T], name key: (T) -> String) -> T? {
        let scored = candidates.map { ($0, score(name, key($0))) }.filter { $0.1 >= 0.75 }
        guard let best = scored.max(by: { $0.1 < $1.1 }) else { return nil }
        let ties = scored.filter { $0.1 == best.1 }
        return ties.count == 1 ? best.0 : nil
    }

    /// A readable display name from an email address: "sarah.chen@acme.com" → "Sarah Chen".
    public static func displayName(fromEmail email: String) -> String {
        tokens(email).map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}
