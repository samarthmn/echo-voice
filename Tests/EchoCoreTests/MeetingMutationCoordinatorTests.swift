import XCTest
@testable import EchoCore

final class MeetingMutationCoordinatorTests: XCTestCase {
    func testExclusiveMutationWaitsForEveryReader() async throws {
        let coordinator = MeetingMutationCoordinator()
        let first = try await coordinator.acquire(meetingID: "meeting", access: .read)
        let second = try await coordinator.acquire(meetingID: "meeting", access: .read)
        let writer = Task { try await coordinator.acquire(meetingID: "meeting", access: .exclusive) }
        await coordinator.waitForQueuedWriter(meetingID: "meeting")
        await first.release()
        let remainingReaders = await coordinator.activeLeaseCount(meetingID: "meeting")
        XCTAssertEqual(remainingReaders, 1)
        await second.release()
        let exclusive = try await writer.value
        let activeWriter = await coordinator.activeLeaseCount(meetingID: "meeting")
        XCTAssertEqual(activeWriter, 1)
        await exclusive.release()
    }

    func testQueuedWriterPreventsNewReadersFromPassingIt() async throws {
        let coordinator = MeetingMutationCoordinator()
        let first = try await coordinator.acquire(meetingID: "meeting", access: .read)
        let writer = Task { try await coordinator.acquire(meetingID: "meeting", access: .exclusive) }
        await coordinator.waitForQueuedWriter(meetingID: "meeting")
        let lateReader = Task { try await coordinator.acquire(meetingID: "meeting", access: .read) }
        await first.release()
        let exclusive = try await writer.value
        let activeWriter = await coordinator.activeLeaseCount(meetingID: "meeting")
        XCTAssertEqual(activeWriter, 1)
        await exclusive.release()
        let reader = try await lateReader.value
        await reader.release()
    }
}
