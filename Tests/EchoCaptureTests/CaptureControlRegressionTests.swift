import AVFoundation
import XCTest
@testable import EchoCapture

@MainActor
final class CaptureControlRegressionTests: XCTestCase {
    private func fixture() async throws -> (URL, ControlledDevices, AudioCaptureController) {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ECHO_TEST_ROOT"] ?? FileManager.default.currentDirectoryPath + "/tmp/tests")
            .appendingPathComponent("capture-controls-\(UUID().uuidString)")
        let devices = try ControlledDevices()
        let capture = AudioCaptureController(devices: devices.provider)
        try await capture.start(.init(meetingID: "meeting", meetingDirectory: root,
                                      application: devices.app, microphone: devices.mic, allowSingleSource: false),
                                onEvent: { _ in })
        return (root, devices, capture)
    }

    func testMuteClosesGateWhileApplicationReplacementIsBlocked() async throws {
        let (root, devices, capture) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        devices.blockNextApplication()
        let transition = Task { try await capture.changeApplication(sourceID: devices.app.id) }
        let started = await semaphoreWait(devices.applicationStarted)
        XCTAssertTrue(started)
        let mute = Task { try await capture.setMicrophoneMuted(true) }
        for _ in 0..<50 {
            if capture.microphoneMuted { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(capture.microphoneMuted)
        XCTAssertNotEqual(devices.initialMicrophone.queue.muteHostTime, 0)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: devices.initialMicrophone.queue.format, frameCapacity: 160))
        buffer.frameLength = 160
        devices.initialMicrophone.queue.push(buffer.audioBufferList, frames: 160, hostTime: mach_absolute_time())
        XCTAssertNil(devices.initialMicrophone.queue.pop(into: buffer), "Post-mute samples must never enter recording")
        devices.releaseApplication.signal()
        try await transition.value
        do { try await mute.value } catch { XCTFail("Mute must wait for teardown after gating: \(error)") }
        XCTAssertTrue(capture.isRecording)
        XCTAssertTrue(capture.recordingFormats.contains { $0.track == .remote })
        await capture.stop()
    }

    func testMutedDisconnectedMicrophoneDoesNotPreventRemoteResume() async throws {
        let (root, devices, capture) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try await capture.setMicrophoneMuted(true)
        devices.disconnectMicrophone()
        try await capture.pause()
        do { try await capture.resume() } catch { XCTFail("Muted microphone must not block meeting audio: \(error)") }
        XCTAssertTrue(capture.isRecording)
        XCTAssertTrue(capture.microphoneMuted)
        XCTAssertEqual(capture.recordingFormats.map(\.track), [.remote])
        await capture.stop()
    }

    func testTemporaryMicrophoneRestartFailureRetriesWithoutUserMute() async throws {
        let (root, devices, capture) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        devices.failNextMicrophoneOpen()
        devices.configurationChanged()
        for _ in 0..<150 {
            if devices.microphoneOpenCount >= 3 && !capture.microphoneMuted { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(devices.microphoneOpenCount, 3, "Initial input, transient failure, and successful retry")
        XCTAssertFalse(capture.microphoneMuted)
        XCTAssertTrue(capture.recordingFormats.contains { $0.track == .microphone })
        XCTAssertTrue(capture.recordingFormats.contains { $0.track == .remote })
        await capture.stop()
    }

    func testMuteDuringMicrophoneOpeningPreventsLateUnmute() async throws {
        let (root, devices, capture) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try await capture.setMicrophoneMuted(true)
        devices.blockNextMicrophone()
        let unmute = Task { try await capture.setMicrophoneMuted(false) }
        let started = await semaphoreWait(devices.microphoneStarted)
        XCTAssertTrue(started)
        let mute = Task { try await capture.setMicrophoneMuted(true) }
        try await Task.sleep(for: .milliseconds(20))
        devices.releaseMicrophone.signal()
        try await unmute.value
        try await mute.value
        XCTAssertTrue(capture.microphoneMuted)
        XCTAssertFalse(capture.recordingFormats.contains { $0.track == .microphone })
        XCTAssertTrue(capture.recordingFormats.contains { $0.track == .remote })
        XCTAssertNotEqual(devices.latestMicrophone.queue.muteHostTime, 0)
        await capture.stop()
    }

    func testUnmuteWhilePausedAdmitsFreshMicrophoneOnResume() async throws {
        let (root, devices, capture) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try await capture.setMicrophoneMuted(true)
        try await capture.pause()
        try await capture.setMicrophoneMuted(false)
        try await capture.resume()
        XCTAssertFalse(capture.microphoneMuted)
        XCTAssertEqual(devices.microphoneOpenCount, 2)
        XCTAssertEqual(devices.latestMicrophone.queue.muteHostTime, 0)
        await capture.stop()
    }

    func testRouteRecoveryExhaustsThreeAttemptsThenRequiresSelection() async throws {
        let (root, devices, capture) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        devices.failNextMicrophoneOpen(count: 3)
        devices.configurationChanged()
        try await Task.sleep(for: .milliseconds(3500))
        XCTAssertEqual(devices.microphoneOpenCount, 4, "Initial capture plus three automatic attempts")
        XCTAssertTrue(capture.microphoneMuted)
        XCTAssertTrue(capture.isRecording)
        devices.configurationChanged()
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(devices.microphoneOpenCount, 4)
        try await capture.changeMicrophone(uid: devices.mic.id)
        XCTAssertFalse(capture.microphoneMuted)
        XCTAssertEqual(devices.microphoneOpenCount, 5)
        await capture.stop()
    }

    func testStableMicrophoneIsNotRestartedWithoutConfigurationChange() async throws {
        let (root, devices, capture) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let opened = devices.microphoneOpenCount
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertEqual(devices.microphoneOpenCount, opened,
                       "Default-output or idle monitor noise must not tear down a stable microphone")
        XCTAssertFalse(capture.microphoneMuted)
        XCTAssertTrue(capture.recordingFormats.contains { $0.track == .microphone })
        await capture.stop()
    }

    func testStopWaitsForInFlightTransitionWithoutOrphaningWaiters() async throws {
        let (root, devices, capture) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        devices.blockNextApplication()
        let transition = Task { try await capture.changeApplication(sourceID: devices.app.id) }
        let started = await semaphoreWait(devices.applicationStarted)
        XCTAssertTrue(started)
        let stop = Task { await capture.stop() }
        try await Task.sleep(for: .milliseconds(50))
        devices.releaseApplication.signal()
        _ = try? await transition.value
        await stop.value
        XCTAssertFalse(capture.isRecording)
        XCTAssertEqual(capture.lifecycleState, .idle)
    }
}

func semaphoreWait(_ semaphore: DispatchSemaphore) async -> Bool {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async { continuation.resume(returning: semaphore.wait(timeout: .now() + 5) == .success) }
    }
}

final class SyntheticInput: CaptureMicrophoneInput, CaptureApplicationInput, @unchecked Sendable {
    let queue: RealtimeBufferQueue
    let processIDs: Set<Int32> = [42]
    init() throws { queue = try RealtimeBufferQueue(format: AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!) }
    func start() throws {}
    func stop() {}
    func teardown() {}
}

final class ControlledDevices: @unchecked Sendable {
    let mic = MicrophoneDevice(id: "synthetic-mic", name: "Synthetic microphone", deviceID: 42)
    let app = AudioSource(id: "synthetic-app", name: "Synthetic meeting", bundleID: nil, processIDs: [42])
    let initialMicrophone: SyntheticInput
    let applicationStarted = DispatchSemaphore(value: 0)
    let releaseApplication = DispatchSemaphore(value: 0)
    let microphoneStarted = DispatchSemaphore(value: 0)
    let releaseMicrophone = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var available = true
    private var shouldBlockApplication = false
    private var shouldBlockMicrophone = false
    private var failures = 0
    private var openCount = 0
    private var notification: (@Sendable () -> Void)?
    private var lastInput: SyntheticInput
    init() throws { initialMicrophone = try SyntheticInput(); lastInput = initialMicrophone }
    var microphoneOpenCount: Int { lock.lock(); defer { lock.unlock() }; return openCount }
    func blockNextApplication() { lock.lock(); shouldBlockApplication = true; lock.unlock() }
    func blockNextMicrophone() { lock.lock(); shouldBlockMicrophone = true; lock.unlock() }
    var latestMicrophone: SyntheticInput { lock.lock(); defer { lock.unlock() }; return lastInput }
    func disconnectMicrophone() { lock.lock(); available = false; lock.unlock() }
    func failNextMicrophoneOpen(count: Int = 1) { lock.lock(); failures = count; lock.unlock() }
    func configurationChanged() { lock.lock(); let callback = notification; lock.unlock(); callback?() }
    var provider: CaptureDeviceProvider {
        CaptureDeviceProvider(
            microphones: { [self] in lock.lock(); defer { lock.unlock() }; return available ? [mic] : [] },
            applications: { [self] in [app] }, requestMicrophone: { true },
            openMicrophone: { [self] _, callback in
                lock.lock(); openCount += 1; notification = callback
                let first = openCount == 1, fail = failures > 0, block = shouldBlockMicrophone
                shouldBlockMicrophone = false
                if fail { failures -= 1 }
                lock.unlock()
                if block { microphoneStarted.signal(); _ = releaseMicrophone.wait(timeout: .now() + 5) }
                if fail { throw CaptureError.audio("Synthetic transient route", -10851) }
                let input = first ? initialMicrophone : try SyntheticInput()
                lock.lock(); lastInput = input; lock.unlock()
                return input
            },
            openApplication: { [self] _ in
                lock.lock(); let block = shouldBlockApplication; shouldBlockApplication = false; lock.unlock()
                if block { applicationStarted.signal(); _ = releaseApplication.wait(timeout: .now() + 5) }
                return try SyntheticInput()
            }
        )
    }
}
