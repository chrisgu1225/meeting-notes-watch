import Foundation
import WatchConnectivity

extension Notification.Name {
    static let watchBridgeEvent = Notification.Name("meetingnotes.watchBridgeEvent")
}

enum WatchBridgeEvent {
    case start(WireProtocol.StartCommand)
    case stop(WireProtocol.StopCommand)
    case mark(sessionID: UUID, startedAt: Date)
    case gap(sessionID: UUID, marker: String)
    case audio(Data)
}

/// Receives watch messages. Audio payloads are copied into memory and are
/// never passed to `transferFile` or `transferUserInfo` (those can be persisted).
final class WatchBridge: NSObject, WCSessionDelegate {
    static let event = Notification.Name.watchBridgeEvent

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    func send(_ message: [String: String]) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return }
        session.sendMessage(WireProtocol.anyDictionary(message), replyHandler: nil, errorHandler: nil)
    }

    func pushContext(language: MeetingLanguage) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        try? WCSession.default.updateApplicationContext(
            WireProtocol.anyDictionary(["language": language.rawValue])
        )
    }

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {}

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        deliver(message)
    }

    func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        let type = message["type"] as? String
        let status: String
        switch type {
        case "start":
            status = "preparing"
        case "stop":
            status = "stopping"
        default:
            status = "ok"
        }
        replyHandler(WireProtocol.anyDictionary(["status": status]))
        deliver(message)
    }

    func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        let owned = Data(messageData)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.event, object: WatchBridgeEvent.audio(owned))
        }
    }

    func session(
        _ session: WCSession,
        didReceiveMessageData messageData: Data,
        replyHandler: @escaping (Data) -> Void
    ) {
        let owned = Data(messageData)
        replyHandler(Data([0x01]))
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.event, object: WatchBridgeEvent.audio(owned))
        }
    }

    private func deliver(_ message: [String: Any]) {
        let event: WatchBridgeEvent?
        if let start = WireProtocol.parseStart(message) {
            event = .start(start)
        } else if let stop = WireProtocol.parseStop(message) {
            event = .stop(stop)
        } else if let mark = WireProtocol.parseMark(message) {
            event = .mark(sessionID: mark.sessionID, startedAt: mark.startedAt)
        } else if let gap = WireProtocol.parseGap(message) {
            event = .gap(sessionID: gap.sessionID, marker: gap.marker)
        } else {
            event = nil
        }
        guard let event else { return }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.event, object: event)
        }
    }
}
