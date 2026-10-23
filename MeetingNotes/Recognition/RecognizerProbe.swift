import Foundation
import Speech

struct ModelStatus: Equatable {
    var speechAuthorized: Bool
    var speechTranscriberAvailable: Bool
    var longFormMandarin: String?
    var longFormEnglish: String?
    var dictationMandarin: String?
    var dictationEnglish: String?
    var classicMandarinOnDevice: Bool
    var classicEnglishOnDevice: Bool
}

enum RecognizerProbe {
    static func probe() async -> ModelStatus {
        async let longFormMandarin = SpeechTranscriber.supportedLocale(equivalentTo: MeetingLanguage.mandarin.locale)
        async let longFormEnglish = SpeechTranscriber.supportedLocale(equivalentTo: MeetingLanguage.australianEnglish.locale)
        async let dictationMandarin = DictationTranscriber.supportedLocale(equivalentTo: MeetingLanguage.mandarin.locale)
        async let dictationEnglish = DictationTranscriber.supportedLocale(equivalentTo: MeetingLanguage.australianEnglish.locale)
        let mandarinSF = SFSpeechRecognizer(locale: MeetingLanguage.mandarin.locale)
        let englishSF = SFSpeechRecognizer(locale: MeetingLanguage.australianEnglish.locale)
        // `await` on the initializer does not await `async let` arguments.
        let longFormMandarinLocale = await longFormMandarin
        let longFormEnglishLocale = await longFormEnglish
        let dictationMandarinLocale = await dictationMandarin
        let dictationEnglishLocale = await dictationEnglish
        return ModelStatus(
            speechAuthorized: SFSpeechRecognizer.authorizationStatus() == .authorized,
            speechTranscriberAvailable: SpeechTranscriber.isAvailable,
            longFormMandarin: longFormMandarinLocale?.identifier(.bcp47),
            longFormEnglish: longFormEnglishLocale?.identifier(.bcp47),
            dictationMandarin: dictationMandarinLocale?.identifier(.bcp47),
            dictationEnglish: dictationEnglishLocale?.identifier(.bcp47),
            classicMandarinOnDevice: mandarinSF?.supportsOnDeviceRecognition ?? false,
            classicEnglishOnDevice: englishSF?.supportsOnDeviceRecognition ?? false
        )
    }

    /// Downloads Apple's on-device assets for the selected language.
    /// This is Apple's model download, not an app server. Assets stay installed
    /// after the reservation is released.
    static func download(language: MeetingLanguage, onStatus: @escaping @Sendable (String) -> Void) async throws {
        var installed = 0
        var errors: [String] = []
        if let locale = await DictationTranscriber.supportedLocale(equivalentTo: language.locale) {
            do {
                try await installDictation(locale: locale, language: language, onStatus: onStatus)
                installed += 1
            } catch {
                errors.append(error.localizedDescription)
            }
        }
        if SpeechTranscriber.isAvailable,
           let locale = await SpeechTranscriber.supportedLocale(equivalentTo: language.locale) {
            do {
                try await installLongForm(locale: locale, onStatus: onStatus)
                installed += 1
            } catch {
                errors.append(error.localizedDescription)
            }
        }
        if installed == 0 {
            throw RecognitionSetupError.modelInstallFailed(errors.first ?? "没有可下载的设备端模型")
        }
        onStatus(errors.isEmpty ? "离线模型已准备好" : "部分模型已准备好")
    }

    private static func installDictation(
        locale: Locale,
        language: MeetingLanguage,
        onStatus: @escaping @Sendable (String) -> Void
    ) async throws {
        let created = try await AssetInventory.reserve(locale: locale)
        do {
            let transcriber = DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
            try await install(module: transcriber, onStatus: onStatus)
            if created { await AssetInventory.release(reservedLocale: locale) }
        } catch {
            if created { await AssetInventory.release(reservedLocale: locale) }
            throw error
        }
    }

    private static func installLongForm(
        locale: Locale,
        onStatus: @escaping @Sendable (String) -> Void
    ) async throws {
        let created = try await AssetInventory.reserve(locale: locale)
        do {
            let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
            try await install(module: transcriber, onStatus: onStatus)
            if created { await AssetInventory.release(reservedLocale: locale) }
        } catch {
            if created { await AssetInventory.release(reservedLocale: locale) }
            throw error
        }
    }

    private static func install(module: any SpeechModule, onStatus: @escaping @Sendable (String) -> Void) async throws {
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) else {
            onStatus("模型已经在这台手机上")
            return
        }
        let progress = request.progress
        let updates = Task {
            while !Task.isCancelled {
                onStatus("正在下载 \(Int(progress.fractionCompleted * 100))%")
                try? await Task.sleep(nanoseconds: 400_000_000)
                if progress.isFinished { break }
            }
        }
        defer { updates.cancel() }
        do {
            try await request.downloadAndInstall()
        } catch {
            throw RecognitionSetupError.modelInstallFailed(error.localizedDescription)
        }
    }
}
