import Foundation

/// Deterministic vocabulary handling that complements acoustic boosting.
public enum Vocabulary {
    /// Rewrites aliases to their term ("cube control" → "kubectl") and fixes the casing of terms the
    /// model already heard correctly ("parakeet" → "Parakeet", "Pgvector" → "pgvector").
    public static func applyCanonicalForms(_ text: String, entries: [VocabularyEntry]) -> String {
        var result = text
        // Longest phrases first so "fluid audio sdk" wins over "fluid audio".
        let rules = entries.flatMap { entry in
            ([entry.term, spokenSplit(entry.term)] + entry.aliases).map { (spoken: $0, written: entry.term) }
        }
        .filter { !$0.spoken.trimmingCharacters(in: .whitespaces).isEmpty }
        .sorted { $0.spoken.count > $1.spoken.count }

        for rule in rules {
            let pattern = #"(?i)(?<![\p{L}\p{N}])"# + NSRegularExpression.escapedPattern(for: rule.spoken)
                + #"(?![\p{L}\p{N}])"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result),
                withTemplate: NSRegularExpression.escapedTemplate(for: rule.written))
        }
        return result
    }

    /// "FluidAudio" → "Fluid Audio", "PostgreSQL" → "Postgre SQL": how a compound brand is usually
    /// transcribed when spoken. Returns the term unchanged when it has no internal word break.
    static func spokenSplit(_ term: String) -> String {
        var out = ""
        let chars = Array(term)
        for (i, c) in chars.enumerated() {
            if i > 0, c.isUppercase, chars[i - 1].isLowercase { out.append(" ") }
            out.append(c)
        }
        return out
    }

    /// Accepts the acoustic rescorer's output only if it did nothing but swap vocabulary terms in.
    ///
    /// FluidAudio's rescorer rebuilds the transcript from word timings, and on short or synthetic
    /// audio it can drop words or punctuation. Since accuracy matters more than recall, any output
    /// that loses non-vocabulary words falls back to the original transcript.
    ///
    /// - Parameter isDictionaryWord: spans made only of real words are never replaced; "database"
    ///   must not become "Supabase" just because they sound alike. Exact spoken matches are
    ///   handled deterministically by `applyCanonicalForms` instead.
    public static func guardRescore(
        original: String, rescored: String, terms: [String],
        isDictionaryWord: (String) -> Bool = { _ in false }
    ) -> String {
        let originalWords = WordErrorRate.normalizedWords(original)
        let rescoredWords = WordErrorRate.normalizedWords(rescored)
        let termWords = Set(terms.flatMap(WordErrorRate.normalizedWords))
        guard rescoredWords != originalWords else { return original }

        // Walk the rescored words. Words kept from the original must appear in the same order;
        // between two kept words, the original span that disappeared must have been replaced
        // by vocabulary words that sound like it ("pure shatum" → "Purushottam", not
        // "staging cluster" → "pgvector").
        var cursor = originalWords.startIndex
        var pending: [String] = []
        var swaps = 0

        func spanIsPlausible(_ span: ArraySlice<String>) -> Bool {
            if span.isEmpty && pending.isEmpty { return true }
            guard !span.isEmpty, !pending.isEmpty, span.count <= pending.count * 3 else { return false }
            guard !span.allSatisfy(isDictionaryWord) else { return false }
            return similarity(span.joined(), pending.joined()) >= 0.5
        }

        for word in rescoredWords {
            if termWords.contains(word), !originalWords[cursor...].contains(word) {
                pending.append(word)
                continue
            }
            guard let found = originalWords[cursor...].firstIndex(of: word),
                  spanIsPlausible(originalWords[cursor..<found])
            else { return original }
            if !pending.isEmpty { swaps += 1 }
            pending = []
            cursor = found + 1
        }
        guard spanIsPlausible(originalWords[cursor...]) else { return original }
        if !pending.isEmpty { swaps += 1 }
        guard swaps > 0 else { return original }

        var result = rescored.trimmingCharacters(in: .whitespaces)
        if let end = original.trimmingCharacters(in: .whitespaces).last, ".!?".contains(end),
           let last = result.last, !".!?".contains(last) {
            result.append(end)
        }
        return result
    }

    /// Character-level similarity in 0...1 (1 − normalized Levenshtein distance).
    static func similarity(_ a: String, _ b: String) -> Double {
        let a = Array(a.lowercased()), b = Array(b.lowercased())
        guard !a.isEmpty || !b.isEmpty else { return 1 }
        var prev = Array(0...b.count)
        for i in a.indices {
            var row = [i + 1]
            for j in b.indices {
                row.append(min(prev[j] + (a[i] == b[j] ? 0 : 1), prev[j + 1] + 1, row[j] + 1))
            }
            prev = row
        }
        return 1 - Double(prev[b.count]) / Double(max(a.count, b.count))
    }
}
