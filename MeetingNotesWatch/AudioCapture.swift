import AVFoundation
import Foundation

/// Captures microphone audio into memory.
///
/// This type does not use `AVAudioRecorder`, `AVAudioFile`, or `FileManager`.
/// Buffers are converted to 16 kHz mono Int16 and handed to a callback.
/// The caller is responsible for dropping them if the iPhone cannot take them.
final class AudioCapture {
    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "meetingnotes.watch.capture")
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var onChunk: ((Data) -> Void)?
    private(set) var isRunning = false

    private let targetFormat: AVAudioFormat = {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(AudioStreamFormat.sampleRate),
            channels: 1,
            interleaved: true
        ) else {
            preconditionFailure("16 kHz mono Int16 is a valid format")
        }
        return format
    }()

    func start(onChunk: @escaping (Data) -> Void) throws {
        if isRunning { stop() }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default, options: [])
        try session.setPreferredSampleRate(Double(AudioStreamFormat.sampleRate))
        try session.setActive(true)

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw CaptureError.noInput
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw CaptureError.converter
        }

        lock.lock()
        self.converter = converter
        self.onChunk = onChunk
        lock.unlock()

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            self?.handle(buffer)
        }
        engine.prepare()
        try engine.start()
        isRunning = true
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock()
        converter = nil
        onChunk = nil
        isRunning = false
        lock.unlock()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let data = convert(buffer)
        let callback = onChunk
        lock.unlock()
        guard let data, let callback else { return }
        queue.async {
            callback(data)
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard let converter else { return nil }
        if !converter.inputFormat.isEqual(buffer.format) || !converter.outputFormat.isEqual(targetFormat) {
            return nil
        }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = max(1, AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)))
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return nil
        }
        let supply = OneShotBuffer(buffer)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supply.supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supply.supplied = true
            inputStatus.pointee = .haveData
            return supply.buffer
        }
        guard status != .error, error == nil, output.frameLength > 0 else { return nil }
        guard let samples = output.int16ChannelData?[0] else { return nil }
        return Data(bytes: samples, count: Int(output.frameLength) * MemoryLayout<Int16>.size)
    }
}

/// Lets an audio-converter callback hand over one buffer without capturing a `var`.
private final class OneShotBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var supplied = false
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
}

enum CaptureError: LocalizedError {
    case noInput
    case converter
    case permission

    var errorDescription: String? {
        switch self {
        case .noInput: "手表麦克风没有准备好。"
        case .converter: "音频格式转不过去。"
        case .permission: "没有麦克风权限。到手表的「设置」里给记要点打开麦克风。"
        }
    }
}
