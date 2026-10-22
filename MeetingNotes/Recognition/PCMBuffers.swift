import AVFoundation
import Foundation

/// Builds PCM buffers in memory. There is no `AVAudioFile` path.
enum PCMBuffers {
    static func int16Buffer(data: Data, sampleRate: Double) -> AVAudioPCMBuffer? {
        guard sampleRate > 0, !data.isEmpty, data.count.isMultiple(of: 2) else { return nil }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: true
        ) else { return nil }
        let frames = AVAudioFrameCount(data.count / MemoryLayout<Int16>.size)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            return nil
        }
        buffer.frameLength = frames
        let copied = data.withUnsafeBytes { raw -> Bool in
            guard let source = raw.baseAddress, let destination = buffer.int16ChannelData?[0] else {
                return false
            }
            // `Data` is not guaranteed to be Int16-aligned. Copy bytes.
            // Apple devices are little-endian, which matches the wire format.
            UnsafeMutableRawPointer(destination).copyMemory(from: source, byteCount: data.count)
            return true
        }
        return copied ? buffer : nil
    }

    static func floatBuffer(data: Data, sampleRate: Double) -> AVAudioPCMBuffer? {
        guard let source = int16Buffer(data: data, sampleRate: sampleRate) else { return nil }
        guard let floatFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: source.format, to: floatFormat) else {
            return nil
        }
        guard let output = AVAudioPCMBuffer(
            pcmFormat: floatFormat,
            frameCapacity: AVAudioFrameCount(source.frameLength)
        ) else { return nil }

        let supply = OneShotBuffer(source)
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
        if status == .error || error != nil { return nil }
        return output
    }
}

/// Lets an audio-converter callback hand over one buffer without capturing a `var`.
private final class OneShotBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var supplied = false
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
}
