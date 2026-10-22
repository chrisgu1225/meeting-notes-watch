import Foundation

/// Stable UTF-8 handoff file for a later minutes writer.
///
/// See README for the parse rules. Keys and the `---` separator do not change
/// between sessions.
enum ExportDocument {
    static let formatIdentifier = "MEETING_NOTES_V1"
    static let separator = "---"

    static let headerKeys = [
        "Title",
        "StartedAt",
        "Timezone",
        "Duration",
        "DurationSeconds",
        "Language",
        "Recognition",
        "Engine",
        "RecognizerLocale",
        "VocabularyApplied",
        "Vocabulary",
        "DroppedAudioChunks",
        "Incomplete",
        "Note"
    ]

    static func filename(for session: MeetingSession) -> String {
        let stamp = AdelaideClock.fileStamp(session.startedAt)
        let slug = filenameSlug(session.displayTitle)
        if slug.isEmpty || slug == "未命名" {
            return "MeetingNotes_\(stamp).txt"
        }
        return "MeetingNotes_\(stamp)_\(slug).txt"
    }

    static func render(_ session: MeetingSession) -> String {
        let vocabulary = VocabularyList.sanitized(session.vocabulary).joined(separator: "; ")
        let lines = [
            formatIdentifier,
            field("Title", singleLine(session.displayTitle)),
            field("StartedAt", AdelaideClock.formatISO(session.startedAt)),
            field("Timezone", AdelaideClock.timeZoneIdentifier),
            field("Duration", AdelaideClock.formatDuration(session.durationSeconds)),
            field("DurationSeconds", String(max(0, session.durationSeconds))),
            field("Language", session.languageIdentifier),
            field("Recognition", singleLine(session.recognition)),
            field("Engine", singleLine(session.engine)),
            field("RecognizerLocale", singleLine(session.recognizerLocale)),
            field("VocabularyApplied", session.vocabularyApplied ? "true" : "false"),
            field("Vocabulary", vocabulary),
            field("DroppedAudioChunks", String(max(0, session.droppedAudioChunks))),
            field("Incomplete", session.incomplete ? "true" : "false"),
            field("Note", singleLine(session.note)),
            separator,
            normalizeNewlines(session.transcript)
        ]
        var text = lines.joined(separator: "\n")
        if !text.hasSuffix("\n") {
            text.append("\n")
        }
        return text
    }

    static func data(for session: MeetingSession) -> Data {
        Data(render(session).utf8)
    }

    struct Parsed: Equatable {
        var fields: [String: String]
        var transcript: String
    }

    /// Splits on the first line that is exactly `---`.
    /// Header values are everything after the first `": "` (timestamps contain colons).
    static func parse(_ text: String) -> Parsed? {
        let normalized = normalizeNewlines(text)
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let separatorIndex = lines.firstIndex(of: separator), separatorIndex > 0 else {
            return nil
        }
        guard lines[0] == formatIdentifier else { return nil }
        var fields: [String: String] = [:]
        for line in lines[1..<separatorIndex] {
            if line.isEmpty { continue }
            if let space = line.range(of: ": ") {
                let key = String(line[..<space.lowerBound])
                let value = String(line[space.upperBound...])
                fields[key] = value
            } else if line.hasSuffix(":") {
                fields[String(line.dropLast())] = ""
            } else {
                return nil
            }
        }
        let body = lines[(separatorIndex + 1)...].joined(separator: "\n")
        let transcript = body.hasSuffix("\n") ? String(body.dropLast()) : body
        return Parsed(fields: fields, transcript: transcript)
    }

    static func filenameSlug(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var slug = ""
        for character in trimmed {
            if character == "/" || character == "\\" || character == ":" || character == "\0" {
                continue
            }
            if character.isWhitespace || character == "\n" {
                slug.append("-")
            } else {
                slug.append(character)
            }
            if slug.count >= 40 { break }
        }
        while slug.contains("--") {
            slug = slug.replacingOccurrences(of: "--", with: "-")
        }
        return slug.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
    }

    private static func field(_ key: String, _ value: String) -> String {
        if value.isEmpty { return "\(key):" }
        return "\(key): \(value)"
    }

    private static func singleLine(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizeNewlines(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }
}
