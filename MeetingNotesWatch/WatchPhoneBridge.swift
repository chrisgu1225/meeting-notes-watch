import Foundation
import WatchConnectivity

/// Watch side of the session. Control messages are dictionaries.
/// Audio goes through `AudioSender`, not through this type.
final class WatchPhoneBridge: NSObject, WCSessionDelegate {
    var onMessage: (([String: Any]) -> Void)?
    var onReachability: ((Bool) -> Void)?
    var onContext: (([String: Any]) -> Void)?

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    var isReachable: Bool {
        WCSession.isSupported() && WCSession.default.activationState == .activated && WCSession.default.isReachable
    }

    func send(_ message: [String: String], completion: ((Bool) -> Void)? = nil) {
        guard WCSession.isSupported() else {
            completion?(false)
            return
        }
        let session = WCSession.default
        guard session.activationState == .activated else {
            completion?(false)
            return
        }
        session.sendMessage(WireProtocol.anyDictionary(message), replyHandler: { _ in
            DispatchQueue.main.async { completion?(true) }
        }, errorHandler: { _ in
            DispatchQueue.main.async { completion?(false) }
        })
    }

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        let context = session.receivedApplicationContext
        let reachable = session.isReachable
        DispatchQueue.main.async {
            self.onReachability?(reachable)
            if !context.isEmpty { self.onContext?(context) }
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        DispatchQueue.main.async { self.onReachability?(reachable) }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        DispatchQueue.main.async { self.onContext?(applicationContext) }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        DispatchQueue.main.async { self.onMessage?(message) }
    }

    func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        replyHandler(WireProtocol.anyDictionary(["status": "ok"]))
        DispatchQueue.main.async { self.onMessage?(message) }
    }
}
