import Foundation

/// Word error rate between a reference and a hypothesis, after the usual normalization
/// (case-folded, punctuation stripped), as used by the eval harness.
public struct WordErrorRate: Sendable, Equatable {
    public let substitutions: Int
    public let deletions: Int
    public let insertions: Int
    public let referenceWords: Int

    public var errors: Int { substitutions + deletions + insertions }
    public var rate: Double { referenceWords == 0 ? (errors == 0 ? 0 : 1) : Double(errors) / Double(referenceWords) }

    public static func compute(reference: String, hypothesis: String) -> WordErrorRate {
        let ref = normalizedWords(reference)
        let hyp = normalizedWords(hypothesis)

        // Levenshtein over words, tracking the operation mix along the cheapest path.
        struct Cell { var cost = 0, sub = 0, del = 0, ins = 0 }
        var prev = (0...hyp.count).map { Cell(cost: $0, ins: $0) }
        for i in ref.indices {
            var row = [Cell(cost: i + 1, del: i + 1)]
            for j in hyp.indices {
                if ref[i] == hyp[j] {
                    row.append(prev[j])
                    continue
                }
                var sub = prev[j]; sub.cost += 1; sub.sub += 1
                var del = prev[j + 1]; del.cost += 1; del.del += 1
                var ins = row[j]; ins.cost += 1; ins.ins += 1
                row.append([sub, del, ins].min { $0.cost < $1.cost }!)
            }
            prev = row
        }
        let best = prev[hyp.count]
        return WordErrorRate(substitutions: best.sub, deletions: best.del, insertions: best.ins, referenceWords: ref.count)
    }

    public static func normalizedWords(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { !$0.isEmpty }
    }
}
