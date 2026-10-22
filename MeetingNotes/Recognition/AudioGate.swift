import Foundation

/// Open/closed flag shared by the main actor and the audio pump.
final class AudioGate: @unchecked Sendable {
    private let lock = NSLock()
    private var open: Bool

    init(open: Bool = true) {
        self.open = open
    }

    func set(_ open: Bool) {
        lock.lock()
        self.open = open
        lock.unlock()
    }

    func isOpen() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return open
    }
}
