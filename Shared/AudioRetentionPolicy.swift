import Foundation

/// Audio from a meeting is allowed to exist only as in-memory buffers.
/// Text (JSON session store, exported `.txt`) is the only thing this app writes.
enum AudioRetentionPolicy {
    static let forbiddenExtensions: Set<String> = [
        "wav", "wave", "caf", "aiff", "aif", "aac", "m4a", "mp3", "mp4",
        "flac", "pcm", "amr", "ogg", "opus", "qta", "mov"
    ]

    static func assertTextFile(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        if forbiddenExtensions.contains(ext) {
            preconditionFailure("Refusing to write an audio file: \(url.lastPathComponent)")
        }
    }
}
