import Foundation

/// In-memory watch → iPhone audio packet.
///
/// Layout (big-endian header, little-endian PCM):
/// 0  magic `MNW1` (4)
/// 4  version UInt8 = 1
/// 5  kind UInt8 = 1 (audio)
/// 6  session UUID (16)
/// 22 sequence UInt32
/// 26 sample rate UInt32
/// 30 frame count UInt32
/// 34 Int16 PCM, little-endian, mono
///
/// Control messages are property-list dictionaries and carry no audio.
enum WireProtocol {
    static let magic = Data("MNW1".utf8)
    static let version: UInt8 = 1
    static let audioKind: UInt8 = 1
    static let headerLength = 34

    struct AudioPacket: Equatable {
        var sessionID: UUID
        var sequence: UInt32
        var sampleRate: UInt32
        var pcm: Data
    }

    static func encodeAudio(
        sessionID: UUID,
        sequence: UInt32,
        sampleRate: UInt32,
        pcm: Data
    ) -> Data? {
        guard pcm.count.isMultiple(of: 2), pcm.count / 2 <= Int(UInt32.max) else { return nil }
        var data = Data()
        data.reserveCapacity(headerLength + pcm.count)
        data.append(magic)
        data.append(version)
        data.append(audioKind)
        data.append(uuidData(sessionID))
        data.append(uint32(sequence))
        data.append(uint32(sampleRate))
        data.append(uint32(UInt32(pcm.count / 2)))
        data.append(pcm)
        return data
    }

    static func decodeAudio(_ data: Data) -> AudioPacket? {
        guard data.count >= headerLength else { return nil }
        guard data.prefix(4) == magic else { return nil }
        guard data[4] == version, data[5] == audioKind else { return nil }
        let uuidBytes = data.subdata(in: 6..<22)
        guard let sessionID = uuid(from: uuidBytes) else { return nil }
        let sequence = readUInt32(data, 22)
        let sampleRate = readUInt32(data, 26)
        let frameCount = readUInt32(data, 30)
        let pcmLength = Int(frameCount) * 2
        guard data.count == headerLength + pcmLength else { return nil }
        let pcm = data.subdata(in: headerLength..<data.count)
        return AudioPacket(
            sessionID: sessionID,
            sequence: sequence,
            sampleRate: sampleRate,
            pcm: pcm
        )
    }

    struct StartCommand: Equatable {
        var sessionID: UUID
        var title: String
        var language: MeetingLanguage
        var startedAt: Date
    }

    static func startMessage(_ command: StartCommand) -> [String: String] {
        [
            "type": "start",
            "sessionId": command.sessionID.uuidString,
            "title": command.title,
            "language": command.language.rawValue,
            "startedAt": AdelaideClock.formatISO(command.startedAt)
        ]
    }

    static func parseStart(_ message: [String: Any]) -> StartCommand? {
        guard string(message, "type") == "start" else { return nil }
        guard
            let idText = string(message, "sessionId"),
            let sessionID = UUID(uuidString: idText),
            let language = MeetingLanguage(rawValue: string(message, "language") ?? ""),
            let startedText = string(message, "startedAt"),
            let startedAt = AdelaideClock.parseISO(startedText)
        else { return nil }
        let title = string(message, "title") ?? ""
        return StartCommand(
            sessionID: sessionID,
            title: title,
            language: language,
            startedAt: startedAt
        )
    }

    struct StopCommand: Equatable {
        var sessionID: UUID
        var durationSeconds: Int
        var droppedChunks: Int
    }

    static func stopMessage(_ command: StopCommand) -> [String: String] {
        [
            "type": "stop",
            "sessionId": command.sessionID.uuidString,
            "durationSeconds": String(command.durationSeconds),
            "droppedChunks": String(command.droppedChunks)
        ]
    }

    static func markMessage(sessionID: UUID, startedAt: Date) -> [String: String] {
        [
            "type": "mark",
            "sessionId": sessionID.uuidString,
            "startedAt": AdelaideClock.formatISO(startedAt)
        ]
    }

    static func parseMark(_ message: [String: Any]) -> (sessionID: UUID, startedAt: Date)? {
        guard string(message, "type") == "mark" else { return nil }
        guard
            let idText = string(message, "sessionId"),
            let sessionID = UUID(uuidString: idText),
            let startedText = string(message, "startedAt"),
            let startedAt = AdelaideClock.parseISO(startedText)
        else { return nil }
        return (sessionID, startedAt)
    }

    static func gapMessage(sessionID: UUID, marker: String) -> [String: String] {
        [
            "type": "gap",
            "sessionId": sessionID.uuidString,
            "marker": marker
        ]
    }

    static func parseGap(_ message: [String: Any]) -> (sessionID: UUID, marker: String)? {
        guard string(message, "type") == "gap" else { return nil }
        guard
            let idText = string(message, "sessionId"),
            let sessionID = UUID(uuidString: idText),
            let marker = string(message, "marker"),
            GapMarker.all.contains(marker)
        else { return nil }
        return (sessionID, marker)
    }

    static func parseStop(_ message: [String: Any]) -> StopCommand? {
        guard string(message, "type") == "stop" else { return nil }
        guard
            let idText = string(message, "sessionId"),
            let sessionID = UUID(uuidString: idText)
        else { return nil }
        return StopCommand(
            sessionID: sessionID,
            durationSeconds: int(message, "durationSeconds") ?? 0,
            droppedChunks: int(message, "droppedChunks") ?? 0
        )
    }

    static func string(_ message: [String: Any], _ key: String) -> String? {
        if let value = message[key] as? String { return value }
        if let value = message[key] as? NSNumber { return value.stringValue }
        return nil
    }

    static func int(_ message: [String: Any], _ key: String) -> Int? {
        if let value = message[key] as? Int { return value }
        if let value = message[key] as? NSNumber { return value.intValue }
        if let value = message[key] as? String { return Int(value) }
        return nil
    }

    private static func uint32(_ value: UInt32) -> Data {
        var big = value.bigEndian
        return Data(bytes: &big, count: 4)
    }

    private static func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        let slice = data.subdata(in: offset..<(offset + 4))
        return slice.withUnsafeBytes { raw in
            UInt32(bigEndian: raw.load(as: UInt32.self))
        }
    }

    private static func uuidData(_ id: UUID) -> Data {
        withUnsafeBytes(of: id.uuid) { Data($0) }
    }

    private static func uuid(from data: Data) -> UUID? {
        guard data.count == 16 else { return nil }
        let bytes = Array(data)
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
