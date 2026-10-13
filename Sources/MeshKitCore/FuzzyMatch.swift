import Foundation

public enum FuzzyMatch {
    /// How well `query` matches `fields`, or nil if it doesn't. Every word of the query must match: as the start of a
    /// word, anywhere in the text, as letters in order ("whtr" finds "Wireless Tracker"), or within one typo.
    public static func score(_ query: String, in fields: [String]) -> Int? {
        let tokens = normalized(query).split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return 0 }
        let text = fields.map(normalized).joined(separator: " ")
        let words = text.split(separator: " ").map(String.init)
        let squashed = text.replacingOccurrences(of: " ", with: "")
        let squashedFields = fields.map { normalized($0).replacingOccurrences(of: " ", with: "") }
        var total = 0
        for token in tokens {
            guard let s = tokenScore(token, words: words, text: text, squashed: squashed, fields: squashedFields) else { return nil }
            total += s
        }
        return total
    }

    private static func tokenScore(_ token: String, words: [String], text: String, squashed: String, fields: [String]) -> Int? {
        if words.contains(where: { $0.hasPrefix(token) }) { return 4 }
        if text.contains(token) || squashed.contains(token) { return 3 }
        if token.count >= 4, fields.contains(where: { isSubsequence(token, of: $0) }) { return 2 }
        if token.count >= 4, words.contains(where: { editDistanceAtMostOne(token, String($0.prefix(token.count))) }) { return 1 }
        return nil
    }

    private static func normalized(_ s: String) -> String {
        let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return String(folded.map { $0.isLetter || $0.isNumber ? $0 : " " })
            .split(separator: " ").joined(separator: " ")
    }

    private static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var it = haystack.makeIterator()
        return needle.allSatisfy { c in while let h = it.next() { if h == c { return true } }; return false }
    }

    private static func editDistanceAtMostOne(_ a: String, _ b: String) -> Bool {
        let a = Array(a), b = Array(b)
        guard abs(a.count - b.count) <= 1 else { return false }
        var i = 0, j = 0, edits = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] { i += 1; j += 1; continue }
            edits += 1
            if edits > 1 { return false }
            if a.count > b.count { i += 1 } else if b.count > a.count { j += 1 } else { i += 1; j += 1 }
        }
        return edits + (a.count - i) + (b.count - j) <= 1
    }
}
