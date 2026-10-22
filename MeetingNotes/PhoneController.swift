import Combine
import Foundation
import UIKit

struct LiveSessionState: Equatable {
    var id: UUID
    var title: String
    var startedAt: Date
    var language: MeetingLanguage
    var engine: String
    var recognition: String
    var vocabularyApplied: Bool
    var recognizerLocale: String
    var status: String
    var preview: String
    var phoneDrops: Int
    var acceptingAudio: Bool
    var record: MeetingSession
}

@MainActor
final class PhoneController: ObservableObject {
    let store = SessionStore()
    let settings = SettingsStore()

    @Published var live: LiveSessionState?
    @Published var preparingMessage: String?
    @Published var lastError: String?
    @Published var modelStatus: ModelStatus?
    @Published var downloadMessage: String?
    @Published var isForeground = true

    private let bridge = WatchBridge()
    private var recognition: LiveRecognitionSession?
    private var prepareTask: Task<Void, Never>?
    private var autosaveTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    private var observer: NSObjectProtocol?
    private var lastTranscriptPush = Date.distantPast
    private var pausedDrops = 0
    private var decodeDrops = 0
    private var insertedPauseGap = false

    init() {
        store.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)
        settings.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)
        observer = NotificationCenter.default.addObserver(
            forName: WatchBridge.event,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let event = notification.object as? WatchBridgeEvent else { return }
            Task { @MainActor in
                self?.handle(event)
            }
        }
        bridge.activate()
        bridge.pushContext(language: settings.language)
    }

    func onAppear() {
        bridge.pushContext(language: settings.language)
        Task { modelStatus = await RecognizerProbe.probe() }
    }

    func setForeground(_ foreground: Bool) {
        let wasForeground = isForeground
        isForeground = foreground
        UIApplication.shared.isIdleTimerDisabled = foreground && live != nil
        guard let recognition, live != nil else { return }
        recognition.setAcceptingAudio(foreground)
        if var live {
            live.acceptingAudio = foreground
            self.live = live
        }
        if !foreground && wasForeground {
            if !insertedPauseGap {
                recognition.insertMarker(GapMarker.phoneBackground)
                insertedPauseGap = true
                publishFromRecognizer()
            }
            bridge.send([
                "type": "status",
                "message": "手机不在前台，这段不会记"
            ])
        }
        if foreground && !wasForeground {
            insertedPauseGap = false
            bridge.send([
                "type": "status",
                "message": "手机回到前台"
            ])
        }
    }

    func languageChanged() {
        bridge.pushContext(language: settings.language)
    }

    func downloadModels() {
        let language = settings.language
        downloadMessage = "开始下载…"
        Task {
            do {
                try await RecognizerProbe.download(language: language) { [weak self] text in
                    Task { @MainActor in self?.downloadMessage = text }
                }
                modelStatus = await RecognizerProbe.probe()
            } catch {
                downloadMessage = error.localizedDescription
            }
        }
    }

    func requestSpeechPermission() {
        Task {
            _ = await SFSpeechRecognizerAuthorization.current()
            modelStatus = await RecognizerProbe.probe()
        }
    }

    func updateSession(_ session: MeetingSession) {
        store.upsert(session)
        if var live, live.id == session.id {
            live.record = session
            live.title = session.title
            live.preview = session.transcript
            self.live = live
        }
    }

    func deleteSession(id: UUID) {
        if live?.id == id {
            lastError = "这场还在听，先在手表上停止。"
            return
        }
        store.delete(id: id)
    }

    func exportToSavedFolder(_ session: MeetingSession) throws -> URL {
        let folder = try settings.resolvedFolder()
        return try ExportCoordinator.write(session, toFolder: folder)
    }

    func makeShareFile(_ session: MeetingSession) throws -> URL {
        try ExportCoordinator.writeTemporary(session)
    }

    func stopFromPhone() {
        guard let live else { return }
        let duration = AdelaideClock.roundedSeconds(Date().timeIntervalSince(live.startedAt))
        bridge.send([
            "type": "pleaseStop",
            "sessionId": live.id.uuidString
        ])
        end(WireProtocol.StopCommand(
            sessionID: live.id,
            durationSeconds: duration,
            droppedChunks: 0
        ))
    }

    func didExport(_ session: MeetingSession) {
        guard settings.deleteAfterExport else { return }
        if live?.id == session.id { return }
        store.delete(id: session.id)
    }

    private func handle(_ event: WatchBridgeEvent) {
        switch event {
        case .start(let command):
            begin(command)
        case .stop(let command):
            end(command)
        case .mark(let sessionID, let startedAt):
            applyMark(sessionID: sessionID, startedAt: startedAt)
        case .gap(let sessionID, let marker):
            guard live?.id == sessionID else { return }
            recognition?.insertMarker(marker)
            publishFromRecognizer()
        case .audio(let data):
            ingest(data)
        }
    }

    private func begin(_ command: WireProtocol.StartCommand) {
        guard live == nil, prepareTask == nil else {
            bridge.send([
                "type": "failed",
                "sessionId": command.sessionID.uuidString,
                "message": "已经有一场记录在进行"
            ])
            return
        }
        lastError = nil
        pausedDrops = 0
        decodeDrops = 0
        insertedPauseGap = false
        preparingMessage = "正在准备识别…"
        prepareTask = Task { [weak self] in
            await self?.prepare(command)
        }
    }

    private func prepare(_ command: WireProtocol.StartCommand) async {
        defer { prepareTask = nil }
        do {
            let session = try await LiveRecognitionSession.make(
                language: command.language,
                vocabulary: settings.vocabulary,
                route: settings.route,
                allowServer: settings.allowAppleServer,
                onStatus: { [weak self] text in
                    Task { @MainActor in self?.preparingMessage = text }
                }
            )
            if Task.isCancelled {
                session.cancel()
                preparingMessage = nil
                return
            }
            session.onChange = { [weak self] in
                self?.publishFromRecognizer()
            }
            recognition = session
            session.setAcceptingAudio(isForeground)
            let title = command.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let record = MeetingSession(
                id: command.sessionID,
                title: title,
                startedAt: command.startedAt,
                durationSeconds: 0,
                languageIdentifier: command.language.rawValue,
                recognition: session.recognition,
                engine: session.engineID,
                recognizerLocale: session.recognizerLocale,
                vocabularyApplied: session.vocabularyApplied,
                vocabulary: settings.vocabulary,
                droppedAudioChunks: 0,
                incomplete: true,
                note: "",
                transcript: ""
            )
            store.upsert(record)
            live = LiveSessionState(
                id: command.sessionID,
                title: title,
                startedAt: command.startedAt,
                language: command.language,
                engine: session.engineID,
                recognition: session.recognition,
                vocabularyApplied: session.vocabularyApplied,
                recognizerLocale: session.recognizerLocale,
                status: session.statusLine,
                preview: "",
                phoneDrops: 0,
                acceptingAudio: isForeground,
                record: record
            )
            preparingMessage = nil
            UIApplication.shared.isIdleTimerDisabled = isForeground
            bridge.send([
                "type": "ready",
                "sessionId": command.sessionID.uuidString,
                "engine": session.engineID,
                "recognition": session.recognition,
                "vocabularyApplied": session.vocabularyApplied ? "true" : "false",
                "recognizerLocale": session.recognizerLocale,
                "message": session.statusLine
            ])
            startAutosave()
            if !isForeground {
                session.setAcceptingAudio(false)
                bridge.send([
                    "type": "status",
                    "message": "请把手机上的记要点留在前台"
                ])
            }
        } catch {
            preparingMessage = nil
            lastError = error.localizedDescription
            bridge.send([
                "type": "failed",
                "sessionId": command.sessionID.uuidString,
                "message": error.localizedDescription
            ])
        }
    }

    private func applyMark(sessionID: UUID, startedAt: Date) {
        guard var live, live.id == sessionID else { return }
        live.startedAt = startedAt
        live.record.startedAt = startedAt
        self.live = live
        store.upsert(live.record)
    }

    private func ingest(_ data: Data) {
        guard var live, let recognition else { return }
        guard let packet = WireProtocol.decodeAudio(data),
              packet.sessionID == live.id,
              packet.sampleRate == AudioStreamFormat.sampleRate,
              packet.pcm.count.isMultiple(of: 2) else {
            decodeDrops += 1
            return
        }
        if !live.acceptingAudio {
            pausedDrops += 1
            return
        }
        recognition.append(packet)
        self.live = live
    }

    private func publishFromRecognizer() {
        guard var live, let recognition else { return }
        live.preview = recognition.preview
        live.phoneDrops = recognition.phoneDrops + pausedDrops + decodeDrops
        live.record.transcript = recognition.joiner.committed
        live.record.note = recognition.failureNote
        live.record.droppedAudioChunks = live.phoneDrops
        live.record.durationSeconds = AdelaideClock.roundedSeconds(Date().timeIntervalSince(live.startedAt))
        self.live = live
        let now = Date()
        if now.timeIntervalSince(lastTranscriptPush) > 0.35 {
            lastTranscriptPush = now
            bridge.send([
                "type": "transcript",
                "sessionId": live.id.uuidString,
                "text": String(live.preview.suffix(280)),
                "message": live.status
            ])
        }
    }

    private func startAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                await self?.autosave()
            }
        }
    }

    private func autosave() {
        guard var live, let recognition else { return }
        live.record.transcript = recognition.preview
        live.record.droppedAudioChunks = recognition.phoneDrops + pausedDrops + decodeDrops
        live.record.durationSeconds = AdelaideClock.roundedSeconds(Date().timeIntervalSince(live.startedAt))
        live.record.note = recognition.failureNote
        live.record.incomplete = true
        self.live = live
        store.upsert(live.record)
    }

    private func end(_ command: WireProtocol.StopCommand) {
        prepareTask?.cancel()
        guard let recognition, var live, live.id == command.sessionID else {
            preparingMessage = nil
            bridge.send([
                "type": "saved",
                "sessionId": command.sessionID.uuidString,
                "message": "已取消"
            ])
            return
        }
        let session = recognition
        self.recognition = nil
        autosaveTask?.cancel()
        Task { [weak self] in
            let result = await session.finish()
            self?.complete(result, live: live, command: command)
        }
        live.status = "正在保存文字…"
        self.live = live
    }

    private func complete(
        _ result: (transcript: String, phoneDrops: Int, note: String),
        live: LiveSessionState,
        command: WireProtocol.StopCommand
    ) {
        var record = live.record
        record.transcript = result.transcript
        record.note = result.note
        record.droppedAudioChunks = result.phoneDrops + command.droppedChunks + pausedDrops + decodeDrops
        record.durationSeconds = command.durationSeconds > 0
            ? command.durationSeconds
            : AdelaideClock.roundedSeconds(Date().timeIntervalSince(live.startedAt))
        record.incomplete = false
        record.vocabulary = settings.vocabulary
        store.upsert(record)
        self.live = nil
        self.recognition = nil
        preparingMessage = nil
        UIApplication.shared.isIdleTimerDisabled = false
        bridge.send([
            "type": "saved",
            "sessionId": command.sessionID.uuidString,
            "message": "已保存"
        ])
    }
}
