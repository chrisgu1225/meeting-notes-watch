import AVFoundation
import Foundation
import Speech

/// On-device SpeechAnalyzer session.
///
/// `SpeechTranscriber` is the long-meeting model and does not read contextual
/// strings. `DictationTranscriber` does, via `AnalysisContext.contextualStrings`.
/// Neither type exists on watchOS.
final class AnalyzerBackend {
    let engineID: String
    let recognition: String
    let recognizerLocale: String
    let vocabularyApplied: Bool
    let statusLine: String

    private let analyzer: SpeechAnalyzer
    private let inputContinuation: AsyncStream<AnalyzerInput>.Continuation
    private var resultTask: Task<Void, Never>?
    private let converter: AnalyzerBufferConverter
    private var ownedLocale: Locale?
    private var pumpTask: Task<Void, Never>?

    private init(
        engineID: String,
        recognition: String,
        recognizerLocale: String,
        vocabularyApplied: Bool,
        statusLine: String,
        analyzer: SpeechAnalyzer,
        inputContinuation: AsyncStream<AnalyzerInput>.Continuation,
        resultTask: Task<Void, Never>,
        converter: AnalyzerBufferConverter,
        ownedLocale: Locale?
    ) {
        self.engineID = engineID
        self.recognition = recognition
        self.recognizerLocale = recognizerLocale
        self.vocabularyApplied = vocabularyApplied
        self.statusLine = statusLine
        self.analyzer = analyzer
        self.inputContinuation = inputContinuation
        self.resultTask = resultTask
        self.converter = converter
        self.ownedLocale = ownedLocale
    }

    static func makeDictation(
        language: MeetingLanguage,
        vocabulary: [String],
        onStatus: @escaping @Sendable (String) -> Void,
        onPhrase: @escaping @Sendable (String, Bool) -> Void
    ) async throws -> AnalyzerBackend {
        guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: language.locale) else {
            throw RecognitionSetupError.localeUnsupported(language.rawValue)
        }
        let terms = VocabularyList.sanitized(vocabulary)
        let preset = DictationTranscriber.Preset.progressiveLongDictation
        let transcriber = DictationTranscriber(
            locale: locale,
            contentHints: preset.contentHints.union([.farField]),
            transcriptionOptions: preset.transcriptionOptions,
            reportingOptions: preset.reportingOptions,
            attributeOptions: preset.attributeOptions
        )
        return try await install(
            module: transcriber,
            locale: locale,
            engineID: EngineID.dictationTranscriber,
            vocabularyApplied: !terms.isEmpty,
            statusLine: terms.isEmpty
                ? "设备端 · 听写模型"
                : "设备端 · 自定义词听写",
            contextTerms: terms,
            onStatus: onStatus,
            onPhrase: onPhrase,
            consume: { onPhrase in
                Task {
                    do {
                        for try await result in transcriber.results {
                            let text = String(result.text.characters)
                            onPhrase(text, result.isFinal)
                        }
                    } catch {
                        // Leave any volatile phrase in place. `finish` commits it.
                    }
                }
            }
        )
    }

    static func makeLongForm(
        language: MeetingLanguage,
        onStatus: @escaping @Sendable (String) -> Void,
        onPhrase: @escaping @Sendable (String, Bool) -> Void
    ) async throws -> AnalyzerBackend {
        guard SpeechTranscriber.isAvailable else {
            throw RecognitionSetupError.localeUnsupported(language.rawValue)
        }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: language.locale) else {
            throw RecognitionSetupError.localeUnsupported(language.rawValue)
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        return try await install(
            module: transcriber,
            locale: locale,
            engineID: EngineID.speechTranscriber,
            vocabularyApplied: false,
            statusLine: "设备端 · 长会议模型（自定义词不参与识别，会写进 txt）",
            contextTerms: nil,
            onStatus: onStatus,
            onPhrase: onPhrase,
            consume: { onPhrase in
                Task {
                    do {
                        for try await result in transcriber.results {
                            let text = String(result.text.characters)
                            onPhrase(text, result.isFinal)
                        }
                    } catch {
                        // Leave any volatile phrase in place. `finish` commits it.
                    }
                }
            }
        )
    }

    func startPump(
        queue: PCMQueue,
        accepting: @escaping @Sendable () -> Bool,
        onDrop: @escaping @Sendable () -> Void
    ) {
        let continuation = inputContinuation
        let converter = converter
        pumpTask = Task {
            while let chunk = await queue.next() {
                if Task.isCancelled { break }
                if !accepting() {
                    onDrop()
                    continue
                }
                guard let buffer = PCMBuffers.int16Buffer(
                    data: chunk.pcm,
                    sampleRate: Double(chunk.sampleRate)
                ) else {
                    onDrop()
                    continue
                }
                do {
                    let converted = try converter.convert(buffer)
                    guard converted.frameLength > 0 else { continue }
                    continuation.yield(AnalyzerInput(buffer: converted))
                } catch {
                    onDrop()
                }
            }
            continuation.finish()
        }
    }

    func finish() async {
        await pumpTask?.value
        inputContinuation.finish()
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            await analyzer.cancelAndFinishNow()
        }
        await resultTask?.value
        resultTask = nil
        await releaseReservation()
    }

    func cancel() {
        pumpTask?.cancel()
        inputContinuation.finish()
        let analyzer = analyzer
        let resultTask = resultTask
        let ownedLocale = ownedLocale
        self.ownedLocale = nil
        self.resultTask = nil
        Task {
            await analyzer.cancelAndFinishNow()
            resultTask?.cancel()
            if let ownedLocale {
                await AssetInventory.release(reservedLocale: ownedLocale)
            }
        }
    }

    private func releaseReservation() async {
        guard let ownedLocale else { return }
        self.ownedLocale = nil
        await AssetInventory.release(reservedLocale: ownedLocale)
    }

    private static func install(
        module: any SpeechModule,
        locale: Locale,
        engineID: String,
        vocabularyApplied: Bool,
        statusLine: String,
        contextTerms: [String]?,
        onStatus: @escaping @Sendable (String) -> Void,
        onPhrase: @escaping @Sendable (String, Bool) -> Void,
        consume: @escaping (@escaping @Sendable (String, Bool) -> Void) -> Task<Void, Never>
    ) async throws -> AnalyzerBackend {
        var ownedLocale: Locale?
        var continuation: AsyncStream<AnalyzerInput>.Continuation?
        var analyzer: SpeechAnalyzer?
        var resultTask: Task<Void, Never>?
        var transferred = false
        do {
            let created = try await AssetInventory.reserve(locale: locale)
            if created { ownedLocale = locale }
            onStatus("正在检查离线语音模型…")
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                let progress = request.progress
                let progressTask = Task {
                    while !Task.isCancelled {
                        let percent = Int(progress.fractionCompleted * 100)
                        onStatus("正在下载苹果的离线语音模型 \(percent)%")
                        try? await Task.sleep(nanoseconds: 400_000_000)
                        if progress.isFinished { break }
                    }
                }
                do {
                    try await request.downloadAndInstall()
                } catch {
                    progressTask.cancel()
                    throw RecognitionSetupError.modelInstallFailed(error.localizedDescription)
                }
                progressTask.cancel()
            }

            guard var format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
                throw RecognitionSetupError.noAudioFormat
            }
            if format.sampleRate == 0 || format.channelCount == 0 {
                guard let fallback = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: Double(AudioStreamFormat.sampleRate),
                    channels: 1,
                    interleaved: false
                ) else { throw RecognitionSetupError.noAudioFormat }
                format = fallback
            }

            let speechAnalyzer = SpeechAnalyzer(modules: [module])
            analyzer = speechAnalyzer
            if let contextTerms {
                let context = AnalysisContext()
                context.contextualStrings[.general] = contextTerms
                try await speechAnalyzer.setContext(context)
            }
            let (stream, inputContinuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
            continuation = inputContinuation
            resultTask = consume(onPhrase)
            try await speechAnalyzer.start(inputSequence: stream)
            transferred = true
            return AnalyzerBackend(
                engineID: engineID,
                recognition: RecognitionPlacementID.onDevice,
                recognizerLocale: locale.identifier(.bcp47),
                vocabularyApplied: vocabularyApplied,
                statusLine: statusLine,
                analyzer: speechAnalyzer,
                inputContinuation: inputContinuation,
                resultTask: resultTask ?? Task {},
                converter: AnalyzerBufferConverter(outputFormat: format),
                ownedLocale: ownedLocale
            )
        } catch {
            if !transferred {
                continuation?.finish()
                resultTask?.cancel()
                if let analyzer {
                    await analyzer.cancelAndFinishNow()
                }
                if let ownedLocale {
                    await AssetInventory.release(reservedLocale: ownedLocale)
                }
            }
            throw error
        }
    }
}
