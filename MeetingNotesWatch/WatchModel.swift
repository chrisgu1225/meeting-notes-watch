import AVFoundation
import Foundation
import WatchKit

enum WatchPhase: Equatable {
    case idle
    case consent
    case preparing
    case listening
    case stopping
    case saved
    case failed(String)
}

@MainActor
final class WatchModel: ObservableObject {
    @Published var phase: WatchPhase = .idle
    @Published var title = ""
    @Published var language: MeetingLanguage = .mandarin
    @Published var phoneReachable = false
    @Published var transcriptTail = ""
    @Published var statusLine = "不留录音"
    @Published var droppedChunks = 0
    @Published var micStartedAt: Date?
    @Published var screenActive = true
    @Published var captureInterrupted = false

    private let bridge = WatchPhoneBridge()
    private let capture = AudioCapture()
    private let sender = AudioSender()
    private var sessionID: UUID?
    private var accumulator = Data()
    private var prepareTimeout: Task<Void, Never>?
    private var interruptionObserver: NSObjectProtocol?
    private var resetObserver: NSObjectProtocol?

    init() {
        bridge.onReachability = { [weak self] reachable in
            Task { @MainActor in self?.phoneReachable = reachable }
        }
        bridge.onContext = { [weak self] context in
            Task { @MainActor in
                guard let self, self.phase == .idle || self.phase == .consent else { return }
                if let raw = context["language"] as? String, let language = MeetingLanguage(rawValue: raw) {
                    self.language = language
                }
            }
        }
        bridge.onMessage = { [weak self] message in
            Task { @MainActor in self?.handle(message) }
        }
        bridge.activate()
        observeAudioSession()
    }

    func openConsent() {
        guard phase == .idle || isFailed else { return }
        phase = .consent
        statusLine = phoneReachable ? "手机已连接" : "先打开手机上的记要点"
    }

    func cancelConsent() {
        phase = .idle
    }

    func confirmAndPrepare() {
        guard phase == .consent else { return }
        guard phoneReachable else {
            phase = .failed("手机没连上。打开 iPhone 上的「记要点」，留在前台，再试。")
            return
        }
        phase = .preparing
        statusLine = "正在要麦克风权限…"
        transcriptTail = ""
        droppedChunks = 0
        accumulator.removeAll()
        let id = UUID()
        sessionID = id
        Task {
            let allowed = await requestMicrophone()
            guard self.phase == .preparing, self.sessionID == id else { return }
            guard allowed else {
                self.fail(CaptureError.permission.localizedDescription)
                return
            }
            self.statusLine = "手机正在准备识别…"
            let command = WireProtocol.StartCommand(
                sessionID: id,
                title: String(self.title.prefix(40)),
                language: self.language,
                startedAt: Date()
            )
            self.bridge.send(WireProtocol.startMessage(command)) { [weak self] ok in
                Task { @MainActor in
                    guard let self else { return }
                    if !ok && self.phase == .preparing && self.sessionID == id {
                        self.fail("没把开始发给手机。把手机 App 留在前台。")
                    }
                }
            }
            self.prepareTimeout?.cancel()
            self.prepareTimeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 180_000_000_000)
                guard let self, self.phase == .preparing, self.sessionID == id else { return }
                self.fail("手机太久没有准备好。看一下手机上的提示，再试一次。")
                self.bridge.send(WireProtocol.stopMessage(WireProtocol.StopCommand(
                    sessionID: id,
                    durationSeconds: 0,
                    droppedChunks: 0
                )))
            }
        }
    }

    func stop() {
        guard let sessionID, phase == .listening || phase == .preparing else { return }
        prepareTimeout?.cancel()
        let duration = micStartedAt.map { AdelaideClock.roundedSeconds(Date().timeIntervalSince($0)) } ?? 0
        flushRemainder()
        capture.stop()
        let drops = sender.stop()
        droppedChunks = drops
        micStartedAt = nil
        accumulator.removeAll()
        phase = .stopping
        statusLine = "正在保存文字…"
        bridge.send(WireProtocol.stopMessage(WireProtocol.StopCommand(
            sessionID: sessionID,
            durationSeconds: duration,
            droppedChunks: drops
        ))) { [weak self] ok in
            Task { @MainActor in
                guard let self, self.phase == .stopping else { return }
                if !ok { self.phase = .saved }
            }
        }
    }

    func dismissEndState() {
        phase = .idle
        statusLine = "不留录音"
        transcriptTail = ""
        captureInterrupted = false
    }

    func sceneBecameActive(_ active: Bool) {
        screenActive = active
        guard phase == .listening, active, !capture.isRunning, !captureInterrupted else { return }
        resumeCapture()
    }

    func absorb(_ pcm: Data) {
        guard phase == .listening else { return }
        accumulator.append(pcm)
        let maxBytes = Int(AudioStreamFormat.sampleRate) * AudioStreamFormat.bytesPerFrame * 2
        if accumulator.count > maxBytes {
            accumulator.removeFirst(accumulator.count - maxBytes)
            sender.addDrop()
            droppedChunks = sender.dropCount
        }
        let size = AudioStreamFormat.chunkBytes
        while accumulator.count >= size {
            let piece = Data(accumulator.prefix(size))
            accumulator.removeFirst(size)
            sender.enqueue(piece)
        }
        droppedChunks = sender.dropCount
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    private func handle(_ message: [String: Any]) {
        let type = message["type"] as? String
        switch type {
        case "ready":
            guard phase == .preparing, let sessionID else { return }
            prepareTimeout?.cancel()
            if let text = message["message"] as? String { statusLine = text }
            beginCapture(sessionID: sessionID)
        case "failed":
            guard phase == .preparing || phase == .listening else { return }
            let text = (message["message"] as? String) ?? "手机没有开始识别。"
            fail(text)
        case "transcript":
            if let text = message["text"] as? String { transcriptTail = text }
            if let text = message["message"] as? String, phase == .listening { statusLine = text }
        case "status":
            if let text = message["message"] as? String { statusLine = text }
        case "pleaseStop":
            guard phase == .listening || phase == .preparing else { return }
            stop()
        case "saved":
            guard phase == .stopping || phase == .listening || phase == .preparing else { return }
            capture.stop()
            _ = sender.stop()
            micStartedAt = nil
            phase = .saved
            statusLine = "已保存到手机"
            WKInterfaceDevice.current().play(.success)
        default:
            break
        }
    }

    private func beginCapture(sessionID: UUID) {
        let started = Date()
        micStartedAt = started
        sender.start(sessionID: sessionID)
        bridge.send(WireProtocol.markMessage(sessionID: sessionID, startedAt: started))
        do {
            try capture.start { [weak self] data in
                Task { @MainActor in
                    self?.absorb(data)
                }
            }
            phase = .listening
            WKInterfaceDevice.current().play(.start)
        } catch {
            sender.stop()
            fail(error.localizedDescription)
            bridge.send(WireProtocol.stopMessage(WireProtocol.StopCommand(
                sessionID: sessionID,
                durationSeconds: 0,
                droppedChunks: sender.dropCount
            )))
        }
    }

    private func resumeCapture() {
        guard phase == .listening else { return }
        do {
            try capture.start { [weak self] data in
                Task { @MainActor in self?.absorb(data) }
            }
            statusLine = "继续听"
        } catch {
            statusLine = error.localizedDescription
        }
    }

    private func flushRemainder() {
        if accumulator.count >= 1_600 {
            sender.enqueue(accumulator)
        }
        accumulator.removeAll()
    }

    private func fail(_ message: String) {
        prepareTimeout?.cancel()
        capture.stop()
        _ = sender.stop()
        micStartedAt = nil
        accumulator.removeAll()
        phase = .failed(message)
        statusLine = message
        WKInterfaceDevice.current().play(.failure)
    }

    private func requestMicrophone() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private func observeAudioSession() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                self?.handleInterruption(notification)
            }
        }
        resetObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.phase == .listening else { return }
                self.capture.stop()
                self.resumeCapture()
            }
        }
    }

    private func handleInterruption(_ notification: Notification) {
        guard phase == .listening || phase == .preparing else { return }
        guard
            let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: raw)
        else { return }
        switch type {
        case .began:
            captureInterrupted = true
            statusLine = "麦克风被打断。电话内容记不下来。"
            WKInterfaceDevice.current().play(.failure)
            if let sessionID {
                bridge.send(WireProtocol.gapMessage(sessionID: sessionID, marker: GapMarker.audioInterruption))
            }
        case .ended:
            captureInterrupted = false
            if phase == .listening && screenActive {
                resumeCapture()
            } else if phase == .listening {
                statusLine = "抬腕后点一下，才会继续听。"
            }
        @unknown default:
            break
        }
    }
}
