import Foundation

/// Persists transcripts as JSON text. Audio is not part of this file.
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [MeetingSession] = []

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init() {
        load()
    }

    func upsert(_ session: MeetingSession) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.append(session)
        }
        sessions.sort { $0.startedAt > $1.startedAt }
        save()
    }

    func delete(id: UUID) {
        sessions.removeAll { $0.id == id }
        save()
    }

    private func load() {
        guard let url = try? Self.fileURL(),
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let file = try? decoder.decode(SessionFile.self, from: data) else {
            return
        }
        sessions = file.sessions.sorted { $0.startedAt > $1.startedAt }
    }

    private func save() {
        do {
            let url = try Self.fileURL()
            AudioRetentionPolicy.assertTextFile(url)
            let payload = SessionFile(version: SessionFile.currentVersion, sessions: sessions)
            let data = try encoder.encode(payload)
            try data.write(to: url, options: [.atomic])
        } catch {
            // The in-memory list stays. The next successful save retries.
        }
    }

    private static func fileURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appendingPathComponent("MeetingNotes", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("sessions.json")
    }
}
