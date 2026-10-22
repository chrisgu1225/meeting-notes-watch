import Foundation
import os
import Speech

/// One meeting's recogniser on the iPhone.
///
/// PCM chunks arrive from the watch, live in `PCMQueue`, and are discarded
/// after the recogniser accepts them. This type never creates an audio file.
@MainActor
final class LiveRecognitionSession {
    let engineID: String
    let recognition: String
    let recognizerLocale: String
    let vocabularyApplied: Bool
    let statusLine: String

    private(set) var joiner = TranscriptJoiner()
    private(set) var phoneDrops = 0
    private(set) var failureNote = ""

    private let queue = PCMQueue()
    private let gate = AudioGate(open: true)
    private let pipe: PhrasePipe
    private var phraseTask: Task<Void, Never>?
    private let analyzer: AnalyzerBackend?
    private let classic: SFSpeechBackend?
    var onChange: (() -> Void)?

    private init(analyzer: AnalyzerBackend?, classic: SFSpeechBackend?, pipe: PhrasePipe) {
        self.analyzer = analyzer
        self.classic = classic
        self.pipe = pipe
        engineID = analyzer?.engineID ?? classic?.engineID ?? EngineID.none
        recognition = analyzer?.recognition ?? classic?.recognition ?? RecognitionPlacementID.onDevice
        recognizerLocale = analyzer?.recognizerLocale ?? classic?.recognizerLocale ?? ""
        vocabularyApplied = analyzer?.vocabularyApplied ?? classic?.vocabularyApplied ?? false
        statusLine = analyzer?.statusLine ?? classic?.statusLine ?? ""
    }

    var preview: String { joiner.preview }

    static func make(
        language: MeetingLanguage,
        vocabulary: [String],
        route: RecognitionRoute,
        allowServer: Bool,
        onStatus: @escaping @Sendable (String) -> Void
    ) async throws -> LiveRecognitionSession {
        let status = await SFSpeechRecognizerAuthorization.current()
        guard status == .authorized else {
            throw RecognitionSetupError.speechPermissionDenied
        }
        return try await build(
            language: language,
            vocabulary: vocabulary,
            route: route,
            allowServer: allowServer,
            onStatus: onStatus
        )
    }

    func append(_ packet: WireProtocol.AudioPacket) {
        let chunk = PCMQueue.Chunk(
            pcm: packet.pcm,
            sampleRate: packet.sampleRate,
            sequence: packet.sequence
        )
        Task { await queue.push(chunk) }
    }

    func setAcceptingAudio(_ accepting: Bool) {
        gate.set(accepting)
    }

    func insertMarker(_ marker: String) {
        joiner.commitMarker(marker)
        onChange?()
    }

    func finish() async -> (transcript: String, phoneDrops: Int, note: String) {
        gate.set(false)
        await queue.finish()
        if let analyzer {
            await analyzer.finish()
        }
        if let classic {
            await classic.finish()
            phoneDrops += classic.heldDrops
        }
        pipe.finish()
        await phraseTask?.value
        joiner.commitVolatile()
        phoneDrops += await queue.dropped
        return (joiner.committed, phoneDrops, failureNote)
    }

    func cancel() {
        gate.set(false)
        pipe.finish()
        phraseTask?.cancel()
        Task { await queue.finish() }
        analyzer?.cancel()
        classic?.cancel()
    }

    private func startPhraseTask() {
        let stream = pipe.stream
        phraseTask = Task { @MainActor [weak self] in
            for await event in stream {
                guard let self else { return }
                switch event {
                case .phrase(let text, let isFinal):
                    if isFinal {
                        self.joiner.commitFinal(text)
                    } else if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.joiner.setVolatile("")
                    } else {
                        self.joiner.setVolatile(text)
                    }
                    self.onChange?()
                case .failure(let message):
                    self.failureNote = message
                    self.joiner.commitMarker(GapMarker.recognizer)
                    self.onChange?()
                case .dropped:
                    self.phoneDrops += 1
                    if self.phoneDrops == 1 || self.phoneDrops.isMultiple(of: 8) {
                        self.joiner.commitMarker(GapMarker.audioDropped)
                    }
                    self.onChange?()
                }
            }
        }
    }

    private static func build(
        language: MeetingLanguage,
        vocabulary: [String],
        route: RecognitionRoute,
        allowServer: Bool,
        onStatus: @escaping @Sendable (String) -> Void
    ) async throws -> LiveRecognitionSession {
        var lastError: Error = RecognitionSetupError.serverDisabled
        for attempt in attempts(route: route) {
            do {
                switch attempt {
                case .dictation:
                    onStatus("准备自定义词听写…")
                    let pipe = PhrasePipe()
                    let backend = try await AnalyzerBackend.makeDictation(
                        language: language,
                        vocabulary: vocabulary,
                        onStatus: onStatus,
                        onPhrase: { text, isFinal in pipe.yield(text, isFinal: isFinal) }
                    )
                    return wire(analyzer: backend, classic: nil, pipe: pipe)
                case .longForm:
                    onStatus("准备长会议模型…")
                    let pipe = PhrasePipe()
                    let backend = try await AnalyzerBackend.makeLongForm(
                        language: language,
                        onStatus: onStatus,
                        onPhrase: { text, isFinal in pipe.yield(text, isFinal: isFinal) }
                    )
                    return wire(analyzer: backend, classic: nil, pipe: pipe)
                case .classic:
                    onStatus("准备经典识别…")
                    let pipe = PhrasePipe()
                    let backend = try SFSpeechBackend.make(
                        language: language,
                        vocabulary: vocabulary,
                        allowServer: allowServer,
                        onPartial: { text in pipe.yield(text, isFinal: false) },
                        onFinalSegment: { text in pipe.yield(text, isFinal: true) },
                        onFailure: { message in pipe.fail(message) }
                    )
                    return wire(analyzer: nil, classic: backend, pipe: pipe)
                }
            } catch {
                lastError = error
                Logger(subsystem: "com.chris.meetingnotes", category: "speech")
                    .error("Recognizer setup failed: \(error.localizedDescription, privacy: .public)")
                if route != .automatic { throw error }
            }
        }
        throw lastError
    }

    private static func wire(
        analyzer: AnalyzerBackend?,
        classic: SFSpeechBackend?,
        pipe: PhrasePipe
    ) -> LiveRecognitionSession {
        let session = LiveRecognitionSession(analyzer: analyzer, classic: classic, pipe: pipe)
        session.startPhraseTask()
        let gate = session.gate
        let onDrop: @Sendable () -> Void = { pipe.drop() }
        analyzer?.startPump(queue: session.queue, accepting: { gate.isOpen() }, onDrop: onDrop)
        classic?.startPump(queue: session.queue, accepting: { gate.isOpen() }, onDrop: onDrop)
        Logger(subsystem: "com.chris.meetingnotes", category: "speech")
            .info("Recognizer ready engine=\(session.engineID, privacy: .public) placement=\(session.recognition, privacy: .public)")
        return session
    }

    private enum Attempt {
        case dictation
        case longForm
        case classic
    }

    private static func attempts(route: RecognitionRoute) -> [Attempt] {
        switch route {
        case .vocabulary: [.dictation]
        case .longForm: [.longForm]
        case .classic: [.classic]
        case .automatic: [.dictation, .longForm, .classic]
        }
    }
}

private enum PhraseEvent {
    case phrase(String, Bool)
    case failure(String)
    case dropped
}

private final class PhrasePipe: @unchecked Sendable {
    let stream: AsyncStream<PhraseEvent>
    private let continuation: AsyncStream<PhraseEvent>.Continuation

    init() {
        let pair = AsyncStream.makeStream(of: PhraseEvent.self)
        stream = pair.stream
        continuation = pair.continuation
    }

    func yield(_ text: String, isFinal: Bool) {
        continuation.yield(.phrase(text, isFinal))
    }

    func fail(_ message: String) {
        continuation.yield(.failure(message))
    }

    func drop() {
        continuation.yield(.dropped)
    }

    func finish() {
        continuation.finish()
    }
}

enum SFSpeechRecognizerAuthorization {
    static func current() async -> SFSpeechRecognizerAuthorizationStatus {
        let existing = SFSpeechRecognizer.authorizationStatus()
        if existing != .notDetermined { return existing }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }
}
