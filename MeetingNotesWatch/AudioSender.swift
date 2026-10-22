import Foundation
import WatchConnectivity

/// Sends PCM to the paired iPhone with `sendMessageData` only.
///
/// `transferUserInfo` and `transferFile` are not used. Those APIs can write a
/// queue to disk. If the phone is unreachable or the send fails, the chunk is
/// dropped and counted.
final class AudioSender {
    private let queue = DispatchQueue(label: "meetingnotes.watch.send")
    private var sessionID: UUID?
    private var sequence: UInt32 = 0
    private var pending: [Data] = []
    private var inFlight = 0
    private var dropped = 0
    private let maxPending = 8
    private let maxInFlight = 2
    private var running = false

    func start(sessionID: UUID) {
        queue.sync {
            self.sessionID = sessionID
            sequence = 0
            pending.removeAll()
            inFlight = 0
            dropped = 0
            running = true
        }
    }

    func enqueue(_ pcm: Data) {
        queue.async {
            guard self.running, self.sessionID != nil else { return }
            if self.pending.count >= self.maxPending {
                self.pending.removeFirst(self.pending.count - self.maxPending + 1)
                self.dropped += 1
            }
            self.pending.append(pcm)
            self.pump()
        }
    }

    func addDrop() {
        queue.async { self.dropped += 1 }
    }

    func stop() -> Int {
        queue.sync {
            running = false
            dropped += pending.count
            pending.removeAll()
            sessionID = nil
            return dropped
        }
    }

    var dropCount: Int {
        queue.sync { dropped }
    }

    private func pump() {
        guard running, inFlight < maxInFlight, !pending.isEmpty else { return }
        guard let sessionID else { return }
        guard WCSession.default.activationState == .activated, WCSession.default.isReachable else {
            dropped += pending.count
            pending.removeAll()
            return
        }
        let pcm = pending.removeFirst()
        let sequence = self.sequence
        self.sequence &+= 1
        guard let packet = WireProtocol.encodeAudio(
            sessionID: sessionID,
            sequence: sequence,
            sampleRate: AudioStreamFormat.sampleRate,
            pcm: pcm
        ) else {
            dropped += 1
            pump()
            return
        }
        inFlight += 1
        WCSession.default.sendMessageData(packet, replyHandler: { _ in
            self.queue.async {
                self.inFlight -= 1
                self.pump()
            }
        }, errorHandler: { _ in
            self.queue.async {
                self.inFlight -= 1
                self.dropped += 1
                self.pump()
            }
        })
    }
}
