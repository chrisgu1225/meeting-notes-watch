import AVFoundation
import Foundation
import Speech

/// SFSpeechRecognizer with a proactive restart around 45 seconds.
///
/// Apple stops a recognition task at about one minute. Restarting keeps a
/// 30–60 minute meeting going. Each task is a new in-memory request.
/// Audio is never written out to bridge the gap between tasks.
final class SFSpeechBackend: NSObject, SFSpeechRecognizerDelegate {
    let engineID: String
    let recognition: String
    let recognizerLocale: String
    let vocabularyApplied: Bool
    let statusLine: String

    private let recognizer: SFSpeechRecognizer
    private let forceOnDevice: Bool
    private let vocabulary: [String]
    private let onPartial: @Sendable (String) -> Void
    private let onFinalSegment: @Sendable (String) -> Void
    private let onFailure: @Sendable (String) -> Void

    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var callbackGeneration = 0
    private var segmentFrames = 0
    private var endingSegment = false
    private var segmentClosed = false
    private var latestPartial = ""
    private var stopped = false
    private var quickFailures = 0
    private var held: [AVAudioPCMBuffer] = []
    private(set) var heldDrops = 0
    private var pumpTask: Task<Void, Never>?
    private var finished = false
    private let segmentLimitFrames = 16_000 * 45

    init(
        recognizer: SFSpeechRecognizer,
        forceOnDevice: Bool,
        vocabulary: [String],
        engineID: String,
        recognition: String,
        statusLine: String,
        onPartial: @escaping @Sendable (String) -> Void,
        onFinalSegment: @escaping @Sendable (String) -> Void,
        onFailure: @escaping @Sendable (String) -> Void
    ) {
        self.recognizer = recognizer
        self.forceOnDevice = forceOnDevice
        self.vocabulary = vocabulary
        self.engineID = engineID
        self.recognition = recognition
        self.recognizerLocale = recognizer.locale.identifier(.bcp47)
        self.vocabularyApplied = !vocabulary.isEmpty
        self.statusLine = statusLine
        self.onPartial = onPartial
        self.onFinalSegment = onFinalSegment
        self.onFailure = onFailure
        super.init()
        recognizer.delegate = self
        startRequest()
    }

    static func make(
        language: MeetingLanguage,
        vocabulary: [String],
        allowServer: Bool,
        onPartial: @escaping @Sendable (String) -> Void,
        onFinalSegment: @escaping @Sendable (String) -> Void,
        onFailure: @escaping @Sendable (String) -> Void
    ) throws -> SFSpeechBackend {
        guard let recognizer = SFSpeechRecognizer(locale: language.locale), recognizer.isAvailable else {
            throw RecognitionSetupError.localeUnsupported(language.rawValue)
        }
        let onDevice = recognizer.supportsOnDeviceRecognition
        if !onDevice && !allowServer {
            throw RecognitionSetupError.onDeviceUnavailable(language.rawValue)
        }
        let server = !onDevice
        return SFSpeechBackend(
            recognizer: recognizer,
            forceOnDevice: onDevice,
            vocabulary: VocabularyList.sanitized(vocabulary),
            engineID: server ? EngineID.sfSpeechServer : EngineID.sfSpeechOnDevice,
            recognition: server ? RecognitionPlacementID.appleServer : RecognitionPlacementID.onDevice,
            statusLine: server
                ? "苹果服务器 · 经典识别（缓冲会送到苹果，不写成文件）"
                : "设备端 · 经典识别，约每 45 秒接一段",
            onPartial: onPartial,
            onFinalSegment: onFinalSegment,
            onFailure: onFailure
        )
    }

    func startPump(
        queue: PCMQueue,
        accepting: @escaping @Sendable () -> Bool,
        onDrop: @escaping @Sendable () -> Void
    ) {
        pumpTask = Task { [weak self] in
            while let chunk = await queue.next() {
                guard let self else { return }
                if Task.isCancelled { break }
                if !accepting() {
                    onDrop()
                    continue
                }
                guard let buffer = PCMBuffers.floatBuffer(
                    data: chunk.pcm,
                    sampleRate: Double(chunk.sampleRate)
                ) else {
                    onDrop()
                    continue
                }
                self.append(buffer)
            }
            self?.beginShutdown()
        }
    }

    func finish() async {
        beginShutdown()
        await pumpTask?.value
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        lock.lock()
        let partial = latestPartial
        let closed = segmentClosed
        if !closed {
            segmentClosed = true
            callbackGeneration += 1
        }
        let task = self.task
        self.task = nil
        self.request = nil
        heldDrops += held.count
        held.removeAll()
        lock.unlock()
        task?.cancel()
        if !closed && !partial.isEmpty {
            onFinalSegment(partial)
        }
    }

    func cancel() {
        lock.lock()
        stopped = true
        callbackGeneration += 1
        let task = self.task
        self.task = nil
        self.request = nil
        held.removeAll()
        lock.unlock()
        task?.cancel()
        pumpTask?.cancel()
    }

    private func beginShutdown() {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        stopped = true
        endingSegment = true
        let request = self.request
        heldDrops += held.count
        held.removeAll()
        lock.unlock()
        request?.endAudio()
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        if stopped {
            lock.unlock()
            return
        }
        if endingSegment || request == nil {
            if held.count >= 16 {
                held.removeFirst()
                heldDrops += 1
            }
            held.append(buffer)
            lock.unlock()
            return
        }
        let request = self.request
        segmentFrames += Int(buffer.frameLength)
        let shouldEnd = segmentFrames >= segmentLimitFrames && !endingSegment
        if shouldEnd { endingSegment = true }
        let generation = callbackGeneration
        lock.unlock()

        request?.append(buffer)
        if shouldEnd {
            request?.endAudio()
            scheduleForceClose(generation: generation)
        }
    }

    private func startRequest() {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = forceOnDevice
        request.contextualStrings = vocabulary
        request.addsPunctuation = true
        request.taskHint = .dictation

        lock.lock()
        callbackGeneration += 1
        let generation = callbackGeneration
        segmentFrames = 0
        endingSegment = false
        segmentClosed = false
        latestPartial = ""
        self.request = request
        let buffered = held
        held = []
        lock.unlock()

        let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            self?.handle(result: result, error: error, generation: generation)
        }
        lock.lock()
        self.task = task
        lock.unlock()

        for buffer in buffered {
            append(buffer)
        }
    }

    private func handle(result: SFSpeechRecognitionResult?, error: Error?, generation: Int) {
        lock.lock()
        let current = callbackGeneration == generation && !segmentClosed
        if current, let result {
            latestPartial = result.bestTranscription.formattedString
        }
        let partial = latestPartial
        let isFinal = result?.isFinal ?? false
        lock.unlock()
        guard current else { return }

        if let result {
            onPartial(result.bestTranscription.formattedString)
        }
        if isFinal || error != nil {
            closeSegment(commit: partial, error: error, generation: generation)
        }
    }

    private func closeSegment(commit: String, error: Error?, generation: Int) {
        lock.lock()
        guard callbackGeneration == generation, !segmentClosed else {
            lock.unlock()
            return
        }
        segmentClosed = true
        callbackGeneration += 1
        let task = self.task
        self.task = nil
        self.request = nil
        let frames = segmentFrames
        let shouldStop = stopped
        if error != nil && commit.isEmpty && frames < 16_000 {
            quickFailures += 1
        } else {
            quickFailures = 0
        }
        let failures = quickFailures
        lock.unlock()
        task?.cancel()

        if !commit.isEmpty {
            onFinalSegment(commit)
        }

        if shouldStop || failures >= 3 {
            if failures >= 3 {
                lock.lock()
                stopped = true
                heldDrops += held.count
                held.removeAll()
                lock.unlock()
                onFailure("识别连续失败，已停下。文字稿保留到这里。")
            }
            return
        }
        startRequest()
    }

    private func scheduleForceClose(generation: Int) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self else { return }
            self.lock.lock()
            let partial = self.latestPartial
            let stillOpen = self.callbackGeneration == generation && !self.segmentClosed
            self.lock.unlock()
            if stillOpen {
                self.closeSegment(commit: partial, error: nil, generation: generation)
            }
        }
    }
}
