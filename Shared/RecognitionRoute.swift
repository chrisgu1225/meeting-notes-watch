import Foundation

/// How the iPhone turns audio buffers into text.
///
/// `Speech` / `SpeechAnalyzer` are not in the watchOS SDK. The watch never
/// recognises speech itself.
enum RecognitionRoute: String, Codable, CaseIterable, Identifiable {
    /// DictationTranscriber if the locale exists, else SpeechTranscriber,
    /// else on-device SFSpeechRecognizer. Server recognition is never used
    /// unless `allowAppleServerRecognition` is on, and then only as the last step.
    case automatic
    /// On-device SpeechTranscriber. Long meetings. Ignores contextual strings.
    case longForm
    /// On-device DictationTranscriber with contextual strings.
    case vocabulary
    /// SFSpeechRecognizer, restarted about every 45 seconds. On-device when it can be.
    case classic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: "自动"
        case .longForm: "长会议模型"
        case .vocabulary: "自定义词听写"
        case .classic: "经典识别（分段）"
        }
    }
}

enum EngineID {
    static let dictationTranscriber = "dictation-transcriber"
    static let speechTranscriber = "speech-transcriber"
    static let sfSpeechOnDevice = "sfspeech-on-device"
    static let sfSpeechServer = "sfspeech-server"
    static let none = "none"
}

enum RecognitionPlacementID {
    /// Audio buffers stay on the iPhone. A language model may have been
    /// downloaded from Apple earlier.
    static let onDevice = "on-device"
    /// SFSpeechRecognizer may send audio buffers to Apple's servers.
    /// The app still does not write an audio file.
    static let appleServer = "apple-server"
}

enum GapMarker {
    static let phoneBackground = "[GAP phone-not-foreground]"
    static let audioDropped = "[GAP audio-dropped]"
    static let audioInterruption = "[GAP audio-interruption]"
    static let recognizer = "[GAP recognizer-restart-failed]"

    static let all: [String] = [
        phoneBackground, audioDropped, audioInterruption, recognizer
    ]
}

enum ConsentScript {
    static let mandarin = "我用 AI 记要点，不留录音"
    static let english = "I'm using AI to take notes, no recording kept"
}

enum AudioStreamFormat {
    static let sampleRate: UInt32 = 16_000
    /// Mono little-endian Int16.
    static let bytesPerFrame = 2
    static let chunkSeconds = 0.2
    static var chunkBytes: Int {
        Int(sampleRate) * bytesPerFrame / 5
    }
}
