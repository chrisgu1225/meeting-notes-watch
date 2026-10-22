import Foundation

enum ExportCoordinator {
    static func write(_ session: MeetingSession, toFolder folder: URL) throws -> URL {
        let accessing = folder.startAccessingSecurityScopedResource()
        defer {
            if accessing { folder.stopAccessingSecurityScopedResource() }
        }
        let filename = ExportDocument.filename(for: session)
        let destination = uniqueURL(folder.appendingPathComponent(filename))
        try write(session, to: destination)
        return destination
    }

    static func writeTemporary(_ session: MeetingSession) throws -> URL {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(ExportDocument.filename(for: session))
        try write(session, to: destination)
        return destination
    }

    static func removeTemporary(_ url: URL) {
        guard url.pathExtension.lowercased() == "txt" else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func write(_ session: MeetingSession, to url: URL) throws {
        AudioRetentionPolicy.assertTextFile(url)
        do {
            try ExportDocument.data(for: session).write(to: url, options: [.atomic])
        } catch {
            throw ExportFailure.writeFailed(error.localizedDescription)
        }
    }

    private static func uniqueURL(_ url: URL) -> URL {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else { return url }
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let folder = url.deletingLastPathComponent()
        var index = 2
        while index < 1000 {
            let candidate = folder.appendingPathComponent("\(stem)-\(index).\(ext)")
            if !manager.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
        return url
    }
}
