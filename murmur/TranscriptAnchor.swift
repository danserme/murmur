import Foundation

nonisolated enum TranscriptAnchor {
    static func utf16Range(in transcript: String, matching query: String) -> NSRange? {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard needle.count >= 8, !transcript.isEmpty else { return nil }

        let haystack = transcript as NSString
        let full = NSRange(location: 0, length: haystack.length)

        let exact = haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive], range: full)
        if exact.location != NSNotFound {
            return exact.length > 80 ? exact : expandToNearbySentences(exact, in: haystack)
        }

        if let phrase = longestMatchingPhrase(needle, in: haystack) {
            return expandToNearbySentences(phrase, in: haystack)
        }

        return bestSentenceWindow(matching: needle, in: transcript)
    }

    private static func longestMatchingPhrase(_ needle: String, in haystack: NSString) -> NSRange? {
        let words = needle.split { $0.isWhitespace || $0.isNewline }.map(String.init)
        guard words.count >= 3 else { return nil }

        let full = NSRange(location: 0, length: haystack.length)
        for length in stride(from: min(words.count, 12), through: 3, by: -1) {
            for start in 0...(words.count - length) {
                let phrase = words[start..<(start + length)].joined(separator: " ")
                let found = haystack.range(of: phrase, options: [.caseInsensitive, .diacriticInsensitive], range: full)
                if found.location != NSNotFound {
                    return found
                }
            }
        }
        return nil
    }

    private static func bestSentenceWindow(matching needle: String, in transcript: String) -> NSRange? {
        let queryTokens = significantTokens(needle)
        guard !queryTokens.isEmpty else { return nil }

        let sentences = sentenceRanges(in: transcript)
        guard !sentences.isEmpty else { return nil }

        var scores = Array(repeating: 0.0, count: sentences.count)
        var bestIndex = 0
        var bestScore = 0.0
        for (index, sentence) in sentences.enumerated() {
            let score = overlapScore(query: queryTokens, in: sentence.text)
            scores[index] = score
            if score > bestScore {
                bestScore = score
                bestIndex = index
            }
        }

        let minimum = queryTokens.count <= 4 ? 1.0 : 2.0
        guard bestScore >= minimum else { return nil }

        var start = bestIndex
        var end = bestIndex
        while start > 0, scores[start - 1] >= 1 {
            start -= 1
            if utf16Length(from: start, to: end, in: sentences) > 500 { start += 1; break }
        }
        while end + 1 < sentences.count, scores[end + 1] >= 1 {
            end += 1
            if utf16Length(from: start, to: end, in: sentences) > 500 { end -= 1; break }
        }

        let first = sentences[start].utf16
        let last = sentences[end].utf16
        return NSRange(location: first.location, length: NSMaxRange(last) - first.location)
    }

    private static func expandToNearbySentences(_ range: NSRange, in haystack: NSString) -> NSRange {
        let sentences = sentenceRanges(in: haystack as String)
        guard let index = sentences.firstIndex(where: { NSIntersectionRange($0.utf16, range).length > 0 }) else {
            return range
        }
        var start = index
        var end = index
        if start > 0 { start -= 1 }
        if end + 1 < sentences.count { end += 1 }
        let first = sentences[start].utf16
        let last = sentences[end].utf16
        let expanded = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
        return expanded.length <= 600 ? expanded : range
    }

    private static func sentenceRanges(in text: String) -> [Sentence] {
        var sentences: [Sentence] = []
        let nsText = text as NSString
        nsText.enumerateSubstrings(in: NSRange(location: 0, length: nsText.length), options: [.bySentences, .localized]) { substring, range, _, _ in
            guard let substring else { return }
            let trimmed = substring.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            sentences.append(Sentence(utf16: range, text: substring))
        }
        return sentences
    }

    private static func overlapScore(query: [String], in sentence: String) -> Double {
        let tokens = significantTokens(sentence)
        guard !tokens.isEmpty else { return 0 }
        let present = Set(tokens)
        let hits = query.filter { present.contains($0) }
        guard !hits.isEmpty else { return 0 }

        var consecutive = 0
        var run = 0
        let sentenceSetOrder = tokens
        for token in query {
            if sentenceSetOrder.contains(token) {
                run += 1
                consecutive = max(consecutive, run)
            } else {
                run = 0
            }
        }
        return Double(hits.count) + Double(consecutive) * 0.5
    }

    private static func significantTokens(_ text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count > 2 && !stopwords.contains($0) }
    }

    private static func utf16Length(from start: Int, to end: Int, in sentences: [Sentence]) -> Int {
        let first = sentences[start].utf16
        let last = sentences[end].utf16
        return NSMaxRange(last) - first.location
    }

    private struct Sentence {
        var utf16: NSRange
        var text: String
    }

    private static let stopwords: Set<String> = [
        "the", "and", "for", "that", "this", "with", "from", "was", "were", "are", "but",
        "not", "you", "your", "they", "them", "their", "have", "has", "had", "been",
        "will", "would", "could", "should", "about", "into", "then", "than", "also",
        "just", "like", "some", "more", "what", "when", "where", "which", "there",
        "here", "its", "our", "out", "all", "any", "can", "did", "does", "doing",
        "title", "overview", "key", "points", "action", "items", "none", "bullet",
    ]
}
