import XCTest
@testable import EchoCore

final class UpdateFoundationTests: XCTestCase {
    func testLegacyModelSelectionDecodesAsNative() throws {
        let selection = try JSONDecoder().decode(ModelSelection.self, from: Data(#"{"id":"notes","revision":"abc"}"#.utf8))
        XCTAssertEqual(selection.provider, .native)
        XCTAssertEqual(selection.id, "notes")
    }
    func testConfigurationIdentityIncludesModelProvider() {
        let native = ProcessingConfiguration(speech: .init(id: "asr", revision: "a"), notes: .init(id: "qwen", revision: "digest", provider: .native))
        let ollama = ProcessingConfiguration(speech: .init(id: "asr", revision: "a"), notes: .init(id: "qwen", revision: "digest", provider: .ollama))
        XCTAssertNotEqual(native.id, ollama.id)
    }
    func testCatalogHasDistinctPurposesAndPinnedNewModels() throws {
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let catalog=try ModelCatalog(url:root.appendingPathComponent("service/models.json"))
        XCTAssertEqual(catalog.models(for:.speech).count,2)
        XCTAssertEqual(catalog.models(for:.notes).count,3)
        XCTAssertEqual(catalog.models(for:.speakers).count,2)
        XCTAssertEqual(catalog.model("gptoss")?.revision,"773a7da77e569019bb0fd17a554b263738d669a3")
    }
    func testVocabularyRejectsAmbiguousAliases() throws {
        XCTAssertThrowsError(try VocabularyEntry.validated([.init(spelling:"Echo Voice",aliases:["echo boys"]),.init(spelling:"Other",aliases:["Echo boys"])]))
        XCTAssertEqual(try VocabularyEntry.validated([.init(spelling:"  Echo   Voice ")])[0].spelling,"Echo Voice")
    }
    func testConfigurationIdentityIncludesVocabularyAndModelRevision() {
        let first=ProcessingConfiguration(speech:.init(id:"asr",revision:"a"))
        var second=first;second.vocabulary=[.init(id:"word",spelling:"Codex")]
        XCTAssertNotEqual(first.id,second.id)
        XCTAssertEqual(first.id,first.id)
    }
    func testEditedWordsLoseTimingUnlessUniquelyUnchanged() {
        let words=[TranscriptWord(id:"one",text:"Hello",location:0,length:5,start:1,end:1.5,source:.nativeWord),TranscriptWord(id:"two",text:"world",location:6,length:5,start:1.5,end:2,source:.nativeWord)]
        let result=TranscriptTiming.preservingUnchangedWords(words,old:"Hello world",new:"Hello friend")
        XCTAssertEqual(result.map(\.id),["one"])
        XCTAssertEqual(TranscriptTiming.preservingUnchangedWords(words,old:"Hello world",new:"Hello Hello").count,0)
    }
}

final class ReviewStorageTests: XCTestCase {
    func testRegenerationActivationPreservesEditsWordsAndAnnotations() throws {
        let root=URL(fileURLWithPath:ProcessInfo.processInfo.environment["ECHO_TEST_ROOT"] ?? FileManager.default.currentDirectoryPath+"/tmp/tests").appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store=try MeetingStore(paths:AppPaths(root:root))
        let meeting=Meeting(id:"review",title:"Review",startedAt:Date(),endedAt:Date(),state:.ready,language:"en",sourceName:"Fixture",usesEchoCancellation:false,transcriptRevision:0)
        try store.createMeeting(meeting)
        let config=ProcessingConfiguration(speech:.init(id:"asr",revision:String(repeating:"a",count:40)))
        try store.setConfiguration(meetingID:meeting.id,configuration:config)
        let word=TranscriptWord(id:"word",text:"original",location:0,length:8,start:0,end:1,source:.nativeWord)
        let original=TranscriptSegment(id:"old",meetingID:meeting.id,windowID:"oldwindow",track:.remote,startTime:0,endTime:2,text:"original phrase",speakerID:nil,isUncertain:false,isProvisional:false,isEdited:false,words:[word])
        try store.upsertSegments([original]);try store.editSegment(id:"old",text:"original correction")
        XCTAssertEqual(try store.segments(meetingID:meeting.id)[0].words?.count,1)
        let oldID=try store.activeTranscriptVersion(meetingID:meeting.id)
        let mark=TranscriptAnnotation(meetingID:meeting.id,kind:.bookmark,startTime:0.5,label:"Important")
        try store.saveAnnotation(mark)
        let highlight = TranscriptAnnotation(meetingID: meeting.id, kind: .highlight, transcriptVersionID: oldID, segmentID: "old", location: 0, length: 8, quote: "original", track: .remote, startTime: 0, endTime: 1)
        try store.saveAnnotation(highlight)
        var version=TranscriptVersion(meetingID:meeting.id,configuration:config,audioFingerprint:"abc")
        try store.saveTranscriptVersion(version)
        let replacement=TranscriptSegment(id:"new",meetingID:meeting.id,windowID:"newwindow",track:.remote,startTime:0,endTime:2,text:"original replacement phrase",speakerID:nil,isUncertain:false,isProvisional:false,isEdited:false)
        try store.saveVersionWindow(versionID:version.id,windowID:"newwindow",segments:[replacement])
        XCTAssertThrowsError(try store.activateTranscriptVersion(version.id,meetingID:meeting.id))
        XCTAssertEqual(try store.segments(meetingID:meeting.id)[0].text,"original correction")
        version.status = .ready;try store.saveTranscriptVersion(version)
        try store.activateTranscriptVersion(version.id,meetingID:meeting.id)
        XCTAssertEqual(try store.segments(meetingID:meeting.id)[0].text,"original replacement phrase")
        XCTAssertTrue(try store.search("correction").isEmpty)
        let annotations = try store.annotations(meetingID: meeting.id)
        XCTAssertTrue(annotations.contains(mark))
        XCTAssertTrue(annotations.contains(highlight))
        XCTAssertTrue(annotations.contains { $0.transcriptVersionID == version.id && $0.quote == "original" && $0.segmentID == "new" })
        try store.activateTranscriptVersion(oldID,meetingID:meeting.id)
        XCTAssertEqual(try store.segments(meetingID:meeting.id)[0].text,"original correction")
        XCTAssertTrue(try store.segments(meetingID:meeting.id)[0].isEdited)
        XCTAssertEqual(try store.search("correction").count,1)
    }
}

final class VocabularyCSVTests: XCTestCase {
    func testQuotedCSVAndUnicodeRoundTrip() throws {
        let input = [VocabularyEntry(spelling: "Echo, Voice", aliases: ["echo boys", "écho"], important: true)]
        let decoded = try VocabularyCSV.parse(VocabularyCSV.export(input))
        XCTAssertEqual(decoded.first?.spelling, input.first?.spelling)
        XCTAssertEqual(decoded.first?.aliases, input.first?.aliases)
        XCTAssertEqual(decoded.first?.important, true)
        XCTAssertThrowsError(try VocabularyCSV.parse("spelling,aliases,enabled,important\n\"unfinished"))
    }
}

final class ReplayIndexTests: XCTestCase {
    func testOverlappingSourcesAndGaps() {
        func segment(_ id: String, _ start: Double, _ end: Double, _ track: AudioTrack) -> TranscriptSegment {
            .init(id: id, meetingID: "m", windowID: id, track: track, startTime: start, endTime: end, text: id, speakerID: nil, isUncertain: false, isProvisional: false, isEdited: false)
        }
        let index = TranscriptIntervalIndex([segment("long", 0, 20, .remote), segment("near", 2, 4, .microphone), segment("later", 25, 30, .remote)])
        XCTAssertEqual(Set(index.active(at: 3).map(\.id)), ["long", "near"])
        XCTAssertEqual(index.active(at: 8).map(\.id), ["long"])
        XCTAssertTrue(index.active(at: 20).isEmpty)
        XCTAssertTrue(index.active(at: .nan).isEmpty)
        XCTAssertEqual(index.active(at: 25).map(\.id), ["later"])
    }
}

final class VisualRetirementTests: XCTestCase {
    func testInterruptedFileRemovalPreservesEditedNotesAndIndependentExports() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ECHO_TEST_ROOT"] ?? FileManager.default.currentDirectoryPath + "/tmp/tests").appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(paths: AppPaths(root: root))
        let meeting = Meeting(id: "retire", title: "Retire", startedAt: Date(), endedAt: Date(), state: .ready, language: "en", sourceName: "Fixture", usesEchoCancellation: false, transcriptRevision: 0)
        try store.createMeeting(meeting)
        let screenshot = ScreenshotRecord(id: "visual", meetingID: meeting.id, relativePath: "screenshots/test.png", capturedAt: 1, perceptualHash: "fixture", interpretation: "Old evidence")
        let image = store.paths.meetingDirectory(meeting.id).appendingPathComponent(screenshot.relativePath)
        try FileManager.default.createDirectory(at: image.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: image)
        try store.addScreenshot(screenshot)
        try store.saveNotes(.init(id: "notes", meetingID: meeting.id, createdAt: Date(), transcriptRevision: 0, summary: [.init(id: "item", text: "Keep my edits", evidenceIDs: [screenshot.id])], decisions: [], actionItems: [], isEdited: true, isPartial: false))
        let external = root.appendingPathComponent("independent-export.txt")
        try Data("Keep export".utf8).write(to: external)
        // Simulate termination after the owned image was removed but before its records.
        struct Journal: Encodable { var meetingID: String; var screenshots: [ScreenshotRecord] }
        let payload = try JSONEncoder().encode(Journal(meetingID: meeting.id, screenshots: [screenshot]))
        try store.database.write { db in try db.execute(sql: "INSERT INTO cleanup_journal(id,payload) VALUES (?,?)", arguments: ["visual-retirement-" + meeting.id, payload]) }
        try FileManager.default.removeItem(at: image)
        try store.retireVisualContext(); try store.retireVisualContext()
        let notes = try XCTUnwrap(store.notes(meetingID: meeting.id).first)
        XCTAssertEqual(notes.summary.first?.text, "Keep my edits")
        XCTAssertTrue(notes.isEdited)
        XCTAssertEqual(notes.summary.first?.evidenceRemoved, true)
        XCTAssertEqual(notes.summary.first?.evidenceIDs, [])
        XCTAssertTrue(try store.screenshots(meetingID: meeting.id).isEmpty)
        XCTAssertEqual(try String(contentsOf: external), "Keep export")
    }
}
