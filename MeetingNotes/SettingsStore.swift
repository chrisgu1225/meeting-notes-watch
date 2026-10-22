import Foundation

@MainActor
final class SettingsStore: ObservableObject {
    @Published var language: MeetingLanguage {
        didSet { defaults.set(language.rawValue, forKey: Keys.language) }
    }
    @Published var route: RecognitionRoute {
        didSet { defaults.set(route.rawValue, forKey: Keys.route) }
    }
    @Published var allowAppleServer: Bool {
        didSet { defaults.set(allowAppleServer, forKey: Keys.allowServer) }
    }
    @Published var vocabulary: [String] {
        didSet { defaults.set(vocabulary, forKey: Keys.vocabulary) }
    }
    @Published var deleteAfterExport: Bool {
        didSet { defaults.set(deleteAfterExport, forKey: Keys.deleteAfterExport) }
    }
    @Published private(set) var folderBookmark: Data?
    @Published private(set) var folderDisplayName: String?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let seeded = defaults.bool(forKey: Keys.seededVocabulary)
        let storedVocabulary = defaults.stringArray(forKey: Keys.vocabulary) ?? []
        if !seeded {
            vocabulary = VocabularyList.defaults
            defaults.set(true, forKey: Keys.seededVocabulary)
            defaults.set(VocabularyList.defaults, forKey: Keys.vocabulary)
        } else {
            vocabulary = VocabularyList.sanitized(storedVocabulary)
        }
        language = MeetingLanguage(rawValue: defaults.string(forKey: Keys.language) ?? "") ?? .mandarin
        route = RecognitionRoute(rawValue: defaults.string(forKey: Keys.route) ?? "") ?? .automatic
        allowAppleServer = defaults.bool(forKey: Keys.allowServer)
        deleteAfterExport = defaults.bool(forKey: Keys.deleteAfterExport)
        folderBookmark = defaults.data(forKey: Keys.folderBookmark)
        folderDisplayName = defaults.string(forKey: Keys.folderName)
    }

    func addTerm(_ raw: String) {
        vocabulary = VocabularyList.sanitized(vocabulary + [raw])
    }

    func removeTerms(at offsets: IndexSet) {
        var copy = vocabulary
        for index in offsets.sorted(by: >) where copy.indices.contains(index) {
            copy.remove(at: index)
        }
        vocabulary = copy
    }

    func restoreDefaultVocabulary() {
        vocabulary = VocabularyList.defaults
    }

    func rememberFolder(_ url: URL) throws {
        // Empty options, not `.minimalBookmark`. A folder picked from Files
        // (iCloud Drive or the Google Drive provider) only stays reachable
        // across launches when the bookmark keeps its security scope.
        // `.withSecurityScope` is macOS-only; iOS includes that scope by default.
        let bookmark = try url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        folderBookmark = bookmark
        folderDisplayName = url.lastPathComponent
        defaults.set(bookmark, forKey: Keys.folderBookmark)
        defaults.set(url.lastPathComponent, forKey: Keys.folderName)
    }

    func clearFolder() {
        folderBookmark = nil
        folderDisplayName = nil
        defaults.removeObject(forKey: Keys.folderBookmark)
        defaults.removeObject(forKey: Keys.folderName)
    }

    /// Resolves the saved Files / iCloud / Drive folder. Caller must
    /// `startAccessingSecurityScopedResource` while writing.
    func resolvedFolder() throws -> URL {
        guard let folderBookmark else { throw ExportFailure.noFolder }
        var stale = false
        let url = try URL(
            resolvingBookmarkData: folderBookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        if stale {
            clearFolder()
            throw ExportFailure.staleBookmark
        }
        return url
    }

    private enum Keys {
        static let language = "meetingnotes.language"
        static let route = "meetingnotes.route"
        static let allowServer = "meetingnotes.allowServer"
        static let vocabulary = "meetingnotes.vocabulary"
        static let seededVocabulary = "meetingnotes.seededVocabulary"
        static let deleteAfterExport = "meetingnotes.deleteAfterExport"
        static let folderBookmark = "meetingnotes.folderBookmark"
        static let folderName = "meetingnotes.folderName"
    }
}

enum ExportFailure: LocalizedError {
    case noFolder
    case staleBookmark
    case notWritable
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .noFolder:
            "还没有选文件夹。可以选 iCloud Drive，或装了 Google Drive 之后选里面的文件夹。"
        case .staleBookmark:
            "之前选的文件夹失效了，请重新选一次。"
        case .notWritable:
            "这个文件夹现在写不进去。"
        case .writeFailed(let message):
            "没有写成 txt：\(message)"
        }
    }
}
