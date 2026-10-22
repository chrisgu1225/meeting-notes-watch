import Foundation

/// Bounded in-memory queue of PCM chunks.
///
/// When the recogniser falls behind, the oldest chunk is dropped. Nothing is
/// written to disk to "catch up".
actor PCMQueue {
    struct Chunk: Sendable, Equatable {
        var pcm: Data
        var sampleRate: UInt32
        var sequence: UInt32
    }

    private var chunks: [Chunk] = []
    private let limit: Int
    private var waiters: [CheckedContinuation<Chunk?, Never>] = []
    private var finished = false
    private(set) var dropped = 0

    init(limit: Int = 12) {
        self.limit = limit
    }

    func push(_ chunk: Chunk) {
        if finished { return }
        if !waiters.isEmpty {
            waiters.removeFirst().resume(returning: chunk)
            return
        }
        if chunks.count >= limit {
            chunks.removeFirst()
            dropped += 1
        }
        chunks.append(chunk)
    }

    func next() async -> Chunk? {
        if !chunks.isEmpty {
            return chunks.removeFirst()
        }
        if finished { return nil }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func finish() {
        finished = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume(returning: nil) }
    }
}
