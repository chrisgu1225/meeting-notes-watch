import AVFoundation
import Foundation

/// Converts microphone PCM to the format `SpeechAnalyzer` asked for.
/// Conversion stays in memory. `AVAudioFile` is intentionally unused.
final class AnalyzerBufferConverter: @unchecked Sendable {
    enum Failure: Error {
        case converterCreationFailed
        case outputBufferAllocationFailed
        case conversionFailed(String)
    }

    private let lock = NSLock()
    private let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?

    init(outputFormat: AVAudioFormat) {
        self.outputFormat = outputFormat
    }

    func convert(_ inputBuffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        lock.lock()
        defer { lock.unlock() }

        if converter == nil
            || converter?.inputFormat.isEqual(inputBuffer.format) == false
            || converter?.outputFormat.isEqual(outputFormat) == false {
            converter = AVAudioConverter(from: inputBuffer.format, to: outputFormat)
            converter?.primeMethod = .none
        }
        guard let converter else { throw Failure.converterCreationFailed }

        let ratio = outputFormat.sampleRate / inputBuffer.format.sampleRate
        let capacity = max(1, AVAudioFrameCount(ceil(Double(inputBuffer.frameLength) * ratio)))
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw Failure.outputBufferAllocationFailed
        }

        final class ConverterInput: @unchecked Sendable {
            let buffer: AVAudioPCMBuffer
            var wasSupplied = false
            init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }
        }

        let source = ConverterInput(buffer: inputBuffer)
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            guard !source.wasSupplied else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            source.wasSupplied = true
            inputStatus.pointee = .haveData
            return source.buffer
        }
        if status == .error || conversionError != nil {
            throw Failure.conversionFailed(conversionError?.localizedDescription ?? "conversion failed")
        }
        return outputBuffer
    }
}
