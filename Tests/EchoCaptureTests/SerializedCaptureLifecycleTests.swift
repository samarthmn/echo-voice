import XCTest
@testable import EchoCapture

final class SerializedCaptureLifecycleTests: XCTestCase {
    @MainActor
    func testPauseWithoutAnActiveRecordingDoesNotReportSuccess() async {
        let capture = AudioCaptureController()
        do {
            try await capture.pause()
            XCTFail("Pause must report that no capture was stopped")
        } catch {
            XCTAssertEqual(capture.lifecycleState, .idle)
        }
    }

    func testCancelledStartDestroysLateHardwareBeforeReturning() async throws {
        let lifecycle = SerializedHardwareLifecycle<FakeHardware>(label: "EchoCaptureTests.cancel")
        let buildStarted = DispatchSemaphore(value: 0)
        let allowBuildToFinish = DispatchSemaphore(value: 0)
        let events = LifecycleEvents()

        let start = Task {
            try await lifecycle.start(
                build: { token in
                    buildStarted.signal()
                    allowBuildToFinish.wait()
                    events.append("built")
                    return (FakeHardware(id: 1), 1)
                },
                discard: { hardware in events.append("discarded-\(hardware.id)") }
            )
        }
        let firstBuildStarted = await waitAsynchronously(buildStarted, timeout: 2)
        XCTAssertEqual(firstBuildStarted, .success)

        lifecycle.requestCancellation()
        allowBuildToFinish.signal()

        do {
            _ = try await start.value
            XCTFail("A cancelled hardware start must not be committed")
        } catch is CancellationError {
            // Expected: cleanup completed before cancellation reached the caller.
        }
        XCTAssertEqual(events.snapshot(), ["built", "discarded-1"])
        let stopped = await lifecycle.stop { hardware in events.append("stopped-\(hardware.id)"); return hardware.id }
        XCTAssertNil(stopped)
    }

    @MainActor
    func testBlockedHardwareStartDoesNotBlockMainActor() async throws {
        let lifecycle = SerializedHardwareLifecycle<FakeHardware>(label: "EchoCaptureTests.responsive")
        let buildStarted = DispatchSemaphore(value: 0)
        let allowBuildToFinish = DispatchSemaphore(value: 0)
        let discarded = LifecycleEvents()
        let start = Task {
            try await lifecycle.start(
                build: { _ in
                    buildStarted.signal()
                    allowBuildToFinish.wait()
                    return (FakeHardware(id: 2), 2)
                },
                discard: { hardware in discarded.append("discarded-\(hardware.id)") }
            )
        }
        let secondBuildStarted = await waitAsynchronously(buildStarted, timeout: 2)
        XCTAssertEqual(secondBuildStarted, .success)

        var mainActorAdvanced = false
        await Task.yield()
        mainActorAdvanced = true
        XCTAssertTrue(mainActorAdvanced)

        lifecycle.requestCancellation()
        allowBuildToFinish.signal()
        do { _ = try await start.value; XCTFail("Expected cancellation") }
        catch is CancellationError {}
        XCTAssertEqual(discarded.snapshot(), ["discarded-2"])
    }

    func testStopRunsAfterStartAndDestroysActiveHardwareExactlyOnce() async throws {
        let lifecycle = SerializedHardwareLifecycle<FakeHardware>(label: "EchoCaptureTests.stop")
        let events = LifecycleEvents()
        let value = try await lifecycle.start(
            build: { _ in events.append("start"); return (FakeHardware(id: 3), "ready") },
            discard: { hardware in events.append("discarded-\(hardware.id)") }
        )
        XCTAssertEqual(value, "ready")

        let first = await lifecycle.stop { hardware in events.append("stopped-\(hardware.id)"); return hardware.id }
        let second = await lifecycle.stop { hardware in events.append("stopped-again-\(hardware.id)"); return hardware.id }

        XCTAssertEqual(first, 3)
        XCTAssertNil(second)
        XCTAssertEqual(events.snapshot(), ["start", "stopped-3"])
    }
}

private func waitAsynchronously(_ semaphore: DispatchSemaphore, timeout: TimeInterval) async -> DispatchTimeoutResult {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(returning: semaphore.wait(timeout: .now() + timeout))
        }
    }
}

private struct FakeHardware: Sendable { let id: Int }

private final class LifecycleEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
    func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return values }
}
