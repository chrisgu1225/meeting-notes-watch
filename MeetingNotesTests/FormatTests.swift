import XCTest
@testable import MeetingNotes

final class FormatTests: XCTestCase {
    func testAdelaideDaylightAndStandardOffsets() {
        let october = Date(timeIntervalSince1970: 1_792_641_600)
        XCTAssertEqual(AdelaideClock.formatISO(october), "2026-10-22T14:30:00+10:30")
        XCTAssertEqual(AdelaideClock.parseISO("2026-10-22T14:30:00+10:30"), october)

        let july = Date(timeIntervalSince1970: 1_784_072_107)
        XCTAssertEqual(AdelaideClock.formatISO(july), "2026-07-15T09:05:07+09:30")
        XCTAssertEqual(AdelaideClock.parseISO(AdelaideClock.formatISO(july)), july)
    }

    func testDurationAndDayLabel() {
        XCTAssertEqual(AdelaideClock.formatDuration(2535), "00:42:15")
        XCTAssertEqual(AdelaideClock.formatDuration(-4), "00:00:00")
        XCTAssertEqual(AdelaideClock.fileStamp(Date(timeIntervalSince1970: 1_792_641_600)), "20261022-143000")

        let now = AdelaideClock.parseISO("2026-10-22T14:30:00+10:30")!
        let yesterday = AdelaideClock.parseISO("2026-10-21T10:00:00+10:30")!
        let older = AdelaideClock.parseISO("2026-10-20T08:00:00+10:30")!
        XCTAssertEqual(AdelaideClock.dayLabel(for: now, now: now), "今天")
        XCTAssertEqual(AdelaideClock.dayLabel(for: yesterday, now: now), "昨天")
        XCTAssertEqual(AdelaideClock.dayLabel(for: older, now: now), "2026年10月20日")
    }

    func testExportRoundTripMatchesStableHeader() throws {
        let session = MeetingSession(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            title: "工地巡查 Ori",
            startedAt: Date(timeIntervalSince1970: 1_792_641_600),
            durationSeconds: 2535,
            languageIdentifier: "zh-CN",
            recognition: RecognitionPlacementID.onDevice,
            engine: EngineID.dictationTranscriber,
            recognizerLocale: "zh-CN",
            vocabularyApplied: true,
            vocabulary: VocabularyList.defaults,
            droppedAudioChunks: 0,
            incomplete: false,
            note: "",
            transcript: "电梯井防水周五前要完成。交给 Jackson。纪要放到 OneDrive。"
        )
        let rendered = ExportDocument.render(session)
        let expected = [
            "MEETING_NOTES_V1",
            "Title: 工地巡查 Ori",
            "StartedAt: 2026-10-22T14:30:00+10:30",
            "Timezone: Australia/Adelaide",
            "Duration: 00:42:15",
            "DurationSeconds: 2535",
            "Language: zh-CN",
            "Recognition: on-device",
            "Engine: dictation-transcriber",
            "RecognizerLocale: zh-CN",
            "VocabularyApplied: true",
            "Vocabulary: Ori; Jackson; ChatGPT; Claude; Grok; Gemini; OneDrive",
            "DroppedAudioChunks: 0",
            "Incomplete: false",
            "Note:",
            "---",
            "电梯井防水周五前要完成。交给 Jackson。纪要放到 OneDrive。",
            ""
        ].joined(separator: "\n")
        XCTAssertEqual(rendered, expected)
        let data = ExportDocument.data(for: session)
        XCTAssertFalse(data.starts(with: [0xEF, 0xBB, 0xBF]))
        XCTAssertFalse(rendered.contains("\r"))
        let parsed = try XCTUnwrap(ExportDocument.parse(rendered))
        XCTAssertEqual(parsed.fields["StartedAt"], "2026-10-22T14:30:00+10:30")
        XCTAssertEqual(parsed.fields["Timezone"], "Australia/Adelaide")
        XCTAssertEqual(parsed.transcript, session.transcript)
        XCTAssertEqual(
            ExportDocument.filename(for: session),
            "MeetingNotes_20261022-143000_工地巡查-Ori.txt"
        )
    }

    func testFilenameStripsPathCharacters() {
        XCTAssertEqual(ExportDocument.filenameSlug("a/b\\c:d"), "abcd")
        XCTAssertEqual(ExportDocument.filenameSlug("   "), "")
    }

    func testVocabularySanitizing() {
        let cleaned = VocabularyList.sanitized([" Ori ", "Ori", "Jack;son", "", "  ", String(repeating: "长", count: 50)])
        XCTAssertEqual(cleaned[0], "Ori")
        XCTAssertEqual(cleaned[1], "Jack son")
        XCTAssertEqual(cleaned[2].count, VocabularyList.maxItemLength)
        XCTAssertEqual(Set(cleaned).count, cleaned.count)
        XCTAssertEqual(VocabularyList.sanitized(Array(repeating: "A", count: 200)).count, VocabularyList.maxCount)
    }

    func testTranscriptJoinerAndMarkers() {
        var joiner = TranscriptJoiner()
        joiner.setVolatile("电梯")
        joiner.setVolatile("电梯井")
        XCTAssertEqual(joiner.preview, "电梯井")
        joiner.commitFinal("电梯井防水")
        joiner.commitFinal("周五前要完成")
        XCTAssertEqual(joiner.committed, "电梯井防水周五前要完成")
        joiner.commitFinal("Jackson")
        XCTAssertEqual(joiner.committed, "电梯井防水周五前要完成 Jackson")
        joiner.commitFinal("said")
        XCTAssertEqual(joiner.committed, "电梯井防水周五前要完成 Jackson said")
        joiner.commitMarker(GapMarker.phoneBackground)
        XCTAssertTrue(joiner.committed.contains("\n\(GapMarker.phoneBackground)"))
        joiner.commitFinal("")
        XCTAssertFalse(joiner.committed.hasSuffix(" "))
    }

    func testAudioPacketRoundTripAndRejection() throws {
        let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let pcm = Data([0x01, 0x00, 0x02, 0x00, 0xFF, 0x7F])
        let encoded = try XCTUnwrap(WireProtocol.encodeAudio(
            sessionID: id,
            sequence: 0x01020304,
            sampleRate: 16_000,
            pcm: pcm
        ))
        XCTAssertEqual(encoded.prefix(4), Data("MNW1".utf8))
        XCTAssertEqual(Array(encoded[22..<26]), [0x01, 0x02, 0x03, 0x04])
        let decoded = try XCTUnwrap(WireProtocol.decodeAudio(encoded))
        XCTAssertEqual(decoded.sessionID, id)
        XCTAssertEqual(decoded.sequence, 0x01020304)
        XCTAssertEqual(decoded.sampleRate, 16_000)
        XCTAssertEqual(decoded.pcm, pcm)

        var badCount = encoded
        badCount[30] = 0x00
        XCTAssertNil(WireProtocol.decodeAudio(badCount))
        XCTAssertNil(WireProtocol.encodeAudio(sessionID: id, sequence: 1, sampleRate: 16_000, pcm: Data([0x01])))
        XCTAssertNil(WireProtocol.decodeAudio(Data("NOPE".utf8)))
    }

    func testControlMessages() throws {
        let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let started = Date(timeIntervalSince1970: 1_792_641_600)
        let start = WireProtocol.startMessage(WireProtocol.StartCommand(
            sessionID: id,
            title: "巡查",
            language: .mandarin,
            startedAt: started
        ))
        let parsed = try XCTUnwrap(WireProtocol.parseStart(start))
        XCTAssertEqual(parsed.sessionID, id)
        XCTAssertEqual(parsed.title, "巡查")
        XCTAssertEqual(parsed.language, .mandarin)
        XCTAssertEqual(parsed.startedAt, started)

        let stop = WireProtocol.stopMessage(WireProtocol.StopCommand(
            sessionID: id,
            durationSeconds: 12,
            droppedChunks: 3
        ))
        XCTAssertEqual(WireProtocol.parseStop(stop)?.droppedChunks, 3)
        let gap = WireProtocol.gapMessage(sessionID: id, marker: GapMarker.audioInterruption)
        XCTAssertEqual(WireProtocol.parseGap(gap)?.marker, GapMarker.audioInterruption)
        XCTAssertNil(WireProtocol.parseGap(["type": "gap", "sessionId": id.uuidString, "marker": "nope"]))
    }

    func testTextExportRefusesAudioExtension() {
        let wav = URL(fileURLWithPath: "/tmp/meeting.wav")
        XCTAssertTrue(AudioRetentionPolicy.forbiddenExtensions.contains("wav"))
        // Calling assert on a text URL must not trap.
        AudioRetentionPolicy.assertTextFile(URL(fileURLWithPath: "/tmp/meeting.txt"))
        XCTAssertTrue(AudioRetentionPolicy.forbiddenExtensions.contains(wav.pathExtension))
    }
}
