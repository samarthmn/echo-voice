import Foundation
import XCTest
@testable import EchoCore

@MainActor
final class TranscriptListModelTests: XCTestCase {
    func testRepeatedManualRevealHasADistinctRequestIdentity() async {
        let model = TranscriptListModel(source: DelayedTranscriptSource())
        await model.load(meetingID: "fast", versionID: "legacy-fast")
        _ = await model.reveal(segmentID: "fast-segment")
        let first = model.revealRequestRevision
        _ = await model.reveal(segmentID: "fast-segment")
        XCTAssertEqual(model.revealRequestRevision, first + 1)
        XCTAssertEqual(model.requestedRevealID, "fast-segment")
    }

    func testUnchangedTimelineDoesNotInvalidateAnInFlightPage() async throws {
        let source = HeldPageTranscriptSource()
        let model = TranscriptListModel(source: source)
        await model.load(meetingID: "meeting", versionID: "legacy-meeting")
        let page = Task { await model.loadPage(containing: 200) }
        await source.waitUntilPageStarts()
        await model.load(meetingID: "meeting", versionID: "legacy-meeting")
        source.releasePage()
        await page.value
        XCTAssertEqual(model.segment(at: 200)?.id, "row-200")
    }

    func testTextEditRefreshesVisiblePageWithoutResettingTranscriptSession() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ECHO_TEST_ROOT"] ?? FileManager.default.currentDirectoryPath + "/tmp/tests")
            .appendingPathComponent("list-edit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(paths: AppPaths(root: root))
        try store.createMeeting(Meeting(id: "meeting", title: "Paging", startedAt: Date(), endedAt: Date(),
                                        state: .ready, language: "en", sourceName: "Test",
                                        usesEchoCancellation: false, transcriptRevision: 0))
        let segments = (0..<200).map { index in
            TranscriptSegment(id: "row-\(index)", meetingID: "meeting", windowID: "window",
                              track: .remote, startTime: Double(index), endTime: Double(index + 1),
                              text: "Original \(index)", speakerID: nil, isUncertain: false,
                              isProvisional: false, isEdited: false)
        }
        try store.replaceSegments(meetingID: "meeting", windowID: "window", segments: segments, isFinal: true)
        let model = TranscriptListModel(store: store)
        await model.load(meetingID: "meeting", versionID: "legacy-meeting")
        let session = model.sessionRevision
        _ = model.consumeChangedRows()
        try store.editSegment(id: "row-7", text: "My correction")
        await model.load(meetingID: "meeting", versionID: "legacy-meeting")
        XCTAssertEqual(model.sessionRevision, session)
        XCTAssertEqual(model.segment(at: 7)?.text, "My correction")
        XCTAssertEqual(model.segment(at: 8)?.text, "Original 8")
        XCTAssertEqual(model.consumeChangedRows(), IndexSet(integer: 7))
    }

    func testShortenedPageIsRejectedBeforeItCanMismatchTimeline() async {
        let model = TranscriptListModel(source: ShortenedTranscriptSource())
        await model.load(meetingID: "meeting", versionID: "legacy-meeting")
        XCTAssertEqual(model.rows.count, 200)
        XCTAssertEqual(model.cachedSegmentCount, 0, "A page from another revision must not be published")
        XCTAssertNil(model.segment(at: 199))
    }

    func testLateResultCannotReplaceNewMeeting() async throws {
        let source = DelayedTranscriptSource()
        let model = TranscriptListModel(source: source)
        let slow = Task { await model.load(meetingID: "slow", versionID: "legacy-slow") }
        await source.waitUntilSlowQueryStarts()

        await model.load(meetingID: "fast", versionID: "legacy-fast")
        source.releaseSlowQuery()
        await slow.value

        XCTAssertEqual(model.rows.map(\.id), ["fast-segment"])
        XCTAssertEqual(model.segment(at: 0)?.text, "fast content")
    }

    func testCacheHoldsAtMostThreePagesAndRevealsOffPageRows() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ECHO_TEST_ROOT"] ?? FileManager.default.currentDirectoryPath + "/tmp/tests")
            .appendingPathComponent("list-model-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(paths: AppPaths(root: root))
        let id = "meeting"
        try store.createMeeting(Meeting(id: id, title: "Paging", startedAt: Date(), endedAt: Date(), state: .ready, language: "en", sourceName: "Test", usesEchoCancellation: false, transcriptRevision: 0))
        for page in 0..<5 {
            let windowID = "window-\(page)"
            let segments = (0..<200).map { offset in
                let index = page * 200 + offset
                return TranscriptSegment(id: "segment-\(index)", meetingID: id, windowID: windowID, track: .remote,
                                         startTime: Double(index), endTime: Double(index + 1), text: "Text \(index)",
                                         speakerID: nil, isUncertain: false, isProvisional: false, isEdited: false)
            }
            try store.replaceSegments(meetingID: id, windowID: windowID, segments: segments, isFinal: true)
        }
        let model = TranscriptListModel(store: store)
        await model.load(meetingID: id, versionID: "legacy-" + id)
        XCTAssertEqual(model.rows.count, 1_000)
        XCTAssertNil(model.segment(at: 800))
        for page in 0..<5 { await model.loadPage(containing: page * 200) }
        XCTAssertLessThanOrEqual(model.cachedSegmentCount, 600)
        XCTAssertEqual(model.segment(at: 800)?.text, "Text 800")
        XCTAssertNil(model.segment(at: 0))
        let revealed = await model.reveal(segmentID: "segment-10")
        XCTAssertEqual(revealed, 10)
        XCTAssertEqual(model.segment(at: 10)?.text, "Text 10")
    }
}

private struct ShortenedTranscriptSource: TranscriptPageSource {
    func transcriptRowIdentities(meetingID: String, versionID: String) throws -> [TranscriptRowIdentity] {
        (0..<200).map { TranscriptRowIdentity(id: "row-\($0)", startTime: Double($0),
                                              endTime: Double($0 + 1), track: .remote, isProvisional: true) }
    }
    func transcriptPage(_ request: TranscriptPageRequest) throws -> TranscriptPage {
        let rows = (0..<199).map { index in
            TranscriptSegment(id: "row-\(index)", meetingID: request.meetingID, windowID: "window",
                              track: .remote, startTime: Double(index), endTime: Double(index + 1),
                              text: "text", speakerID: nil, isUncertain: false,
                              isProvisional: true, isEdited: false)
        }
        return TranscriptPage(rows: rows, precedingCursor: nil, followingCursor: nil, transcriptRevision: 1)
    }
}

private final class DelayedTranscriptSource: TranscriptPageSource, @unchecked Sendable {
    private let started = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)

    func waitUntilSlowQueryStarts() async {
        await Task.detached { [started] in started.wait() }.value
    }
    func releaseSlowQuery() { release.signal() }

    func transcriptRowIdentities(meetingID: String, versionID: String) throws -> [TranscriptRowIdentity] {
        if meetingID == "slow" { started.signal(); release.wait() }
        return [TranscriptRowIdentity(id: meetingID + "-segment", startTime: 0, endTime: 1, track: .remote, isProvisional: false)]
    }
    func transcriptPage(_ request: TranscriptPageRequest) throws -> TranscriptPage {
        let segment = TranscriptSegment(id: request.meetingID + "-segment", meetingID: request.meetingID,
                                        windowID: "window", track: .remote, startTime: 0, endTime: 1,
                                        text: request.meetingID + " content", speakerID: nil,
                                        isUncertain: false, isProvisional: false, isEdited: false)
        return TranscriptPage(rows: [segment], precedingCursor: nil, followingCursor: nil, transcriptRevision: 0)
    }
}

private final class HeldPageTranscriptSource: TranscriptPageSource, @unchecked Sendable {
    private let started = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)
    func waitUntilPageStarts() async { await Task.detached { [started] in started.wait() }.value }
    func releasePage() { released.signal() }
    func transcriptRowIdentities(meetingID: String, versionID: String) throws -> [TranscriptRowIdentity] {
        (0..<400).map { TranscriptRowIdentity(id: "row-\($0)", startTime: Double($0),
                                              endTime: Double($0 + 1), track: .remote, isProvisional: false) }
    }
    func transcriptPage(_ request: TranscriptPageRequest) throws -> TranscriptPage {
        let start = request.anchor == nil ? 0 : 200
        if start == 200 { started.signal(); released.wait() }
        let rows = (start..<start + 200).map { index in
            TranscriptSegment(id: "row-\(index)", meetingID: request.meetingID, windowID: "window",
                              track: .remote, startTime: Double(index), endTime: Double(index + 1),
                              text: "Synthetic", speakerID: nil, isUncertain: false,
                              isProvisional: false, isEdited: false)
        }
        return TranscriptPage(rows: rows, precedingCursor: nil, followingCursor: nil, transcriptRevision: 0)
    }
}
