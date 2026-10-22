import Foundation

struct MeetingSession: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String
    var startedAt: Date
    var durationSeconds: Int
    var languageIdentifier: String
    var recognition: String
    var engine: String
    var recognizerLocale: String
    var vocabularyApplied: Bool
    var vocabulary: [String]
    var droppedAudioChunks: Int
    var incomplete: Bool
    var note: String
    var transcript: String

    var language: MeetingLanguage {
        MeetingLanguage(rawValue: languageIdentifier) ?? .mandarin
    }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未命名" : trimmed
    }

    var durationLabel: String {
        AdelaideClock.formatDuration(durationSeconds)
    }
}

struct SessionFile: Codable, Equatable {
    var version: Int
    var sessions: [MeetingSession]

    static let currentVersion = 1
}
