import Foundation

/// Joins recogniser phrases into one transcript.
///
/// Volatile text is the current guess and is replaced, not appended.
/// Final text is appended once. Gap markers stay on their own line so a later
/// minutes writer can see that audio was discarded rather than stored.
struct TranscriptJoiner: Equatable {
    private(set) var committed: String = ""
    private(set) var volatileText: String = ""

    var preview: String {
        join(committed, volatileText)
    }

    mutating func setVolatile(_ text: String) {
        volatileText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    mutating func commitFinal(_ text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        volatileText = ""
        guard !cleaned.isEmpty else { return }
        committed = join(committed, cleaned)
    }

    mutating func commitVolatile() {
        commitFinal(volatileText)
    }

    mutating func commitMarker(_ marker: String) {
        volatileText = ""
        if committed.isEmpty {
            committed = marker
            return
        }
        let base = committed.hasSuffix("\n") ? String(committed.dropLast()) : committed
        committed = base + "\n" + marker
    }

    func tail(maxCharacters: Int) -> String {
        let text = preview
        guard text.count > maxCharacters else { return text }
        return String(text.suffix(maxCharacters))
    }

    private func join(_ left: String, _ right: String) -> String {
        if left.isEmpty { return right }
        if right.isEmpty { return left }
        if left.hasSuffix(" ") || left.hasSuffix("\n") || right.hasPrefix(" ") || right.hasPrefix("\n") {
            return left + right
        }
        guard let last = left.last, let first = right.first else { return left + right }
        if Self.isCJK(last), Self.isCJK(first) {
            return left + right
        }
        return left + " " + right
    }

    private static func isCJK(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        let value = scalar.value
        return (0x4E00...0x9FFF).contains(value)
            || (0x3400...0x4DBF).contains(value)
            || (0x3000...0x303F).contains(value)
            || (0xFF00...0xFFEF).contains(value)
    }
}
