import Foundation

enum VocabularyList {
    static let defaults: [String] = [
        "Ori", "Jackson", "ChatGPT", "Claude", "Grok", "Gemini", "OneDrive"
    ]

    /// Apple documents a cap of about 100 contextual phrases.
    static let maxCount = 100
    static let maxItemLength = 40

    static func sanitized(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for item in raw {
            let cleaned = sanitizeItem(item)
            guard !cleaned.isEmpty, !seen.contains(cleaned) else { continue }
            seen.insert(cleaned)
            result.append(cleaned)
            if result.count == maxCount { break }
        }
        return result
    }

    static func sanitizeItem(_ raw: String) -> String {
        let collapsed = raw
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: ";", with: " ")
        let trimmed = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= maxItemLength { return trimmed }
        let end = trimmed.index(trimmed.startIndex, offsetBy: maxItemLength)
        return String(trimmed[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
