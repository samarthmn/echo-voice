import Foundation
import AppKit
import AVFoundation
import CoreAudio
import EchoCore

public enum CaptureLifecycleState: String, Sendable {
    case idle, starting, recording, paused, stopping
}

private struct PreparedCaptureHardware: Sendable {
    let worker: RecordingWorker
    let formats: [CaptureAudioFormat]
    let applicationProcessIDs: Set<Int32>?
    let microphoneQueue: RealtimeBufferQueue?
}

/// The lifecycle queue is this object's sole mutable owner. Its explicit,
/// idempotent teardown keeps Core Audio destruction off the main actor.
private final class CaptureHardwareSession: @unchecked Sendable {
    private(set) var microphone: (any CaptureMicrophoneInput)?
    private(set) var application: (any CaptureApplicationInput)?
    private let devices: CaptureDeviceProvider
    private let microphoneGate: MicrophoneAdmissionGate
    let worker: RecordingWorker
    let prepared: PreparedCaptureHardware
    private var tornDown = false

    init(microphone: (any CaptureMicrophoneInput)?, application: (any CaptureApplicationInput)?, worker: RecordingWorker, formats: [CaptureAudioFormat], devices: CaptureDeviceProvider, microphoneGate: MicrophoneAdmissionGate) {
        self.microphone = microphone
        self.application = application
        self.worker = worker
        self.devices = devices
        self.microphoneGate = microphoneGate
        prepared = PreparedCaptureHardware(worker: worker, formats: formats, applicationProcessIDs: application?.processIDs, microphoneQueue: microphone?.queue)
    }

    func start(_ token: HardwareCancellationToken) throws {
        do {
            try token.checkCancellation()
            try microphone?.start()
            try token.checkCancellation()
            try application?.start()
            try token.checkCancellation()
        } catch {
            teardown()
            throw error
        }
    }

    func teardown() {
        guard !tornDown else { return }
        tornDown = true
        microphone?.teardown()
        application?.teardown()
    }

    func stopMicrophone() throws {
        defer { microphone?.teardown(); microphone = nil }
        try worker.closeTrack(.microphone)
    }

    func startMicrophone(device: MicrophoneDevice,
                         onConfigurationChange: @escaping @Sendable () -> Void,
                         preflight: @Sendable (CaptureAudioFormat) throws -> Void) throws -> RealtimeBufferQueue {
        guard microphone == nil else { throw CaptureError.invalidConfiguration }
        let fresh = try devices.openMicrophone(device, onConfigurationChange)
        do {
            microphoneGate.register(fresh.queue)
            try preflight(CaptureAudioFormat(track: .microphone, sampleRate: fresh.queue.format.sampleRate,
                                             channels: fresh.queue.format.channelCount))
            try worker.addTrack(.microphone, ring: fresh.queue)
            try fresh.start()
            microphone = fresh
            return fresh.queue
        } catch {
            try? worker.closeTrack(.microphone)
            fresh.teardown()
            throw error
        }
    }

    func stopApplication() throws {
        application?.stop()
        defer { application?.teardown(); application = nil }
        try worker.closeTrack(.remote)
    }

    func startApplication(source: AudioSource) throws -> (RealtimeBufferQueue, Set<Int32>) {
        guard application == nil else { throw CaptureError.invalidConfiguration }
        let fresh = try devices.openApplication(source)
        do {
            try worker.addTrack(.remote, ring: fresh.queue)
            try fresh.start()
            application = fresh
            return (fresh.queue, fresh.processIDs)
        } catch {
            try? worker.closeTrack(.remote)
            fresh.teardown()
            throw error
        }
    }
}

@MainActor
public final class AudioCaptureController {
    private var configuration: CaptureConfiguration?
    private var onEvent: (@Sendable (CaptureEvent) -> Void)?
    private var worker: RecordingWorker?
    private var activeFormats: [CaptureAudioFormat] = []
    private var applicationProcessIDs: Set<Int32>?
    private var selectedMicrophone: MicrophoneDevice?
    private var selectedApplication: AudioSource?
    private var microphoneQueue: RealtimeBufferQueue?
    private var microphoneGap: CaptureGap?
    private var applicationGap: CaptureGap?
    private var microphoneRecoveryTask: Task<Void, Never>?
    private var microphoneRecoveryAttempts: [Double] = []
    private var microphoneRecoveryEarliest: ContinuousClock.Instant?
    private var desiredMicrophoneMuted = false
    private var microphoneRecoveryRequiresSelection = false
    private let microphoneGate = MicrophoneAdmissionGate()
    private var lastMicrophoneFormat: CaptureAudioFormat?
    private var deviceListeners: [(AudioObjectPropertySelector, AudioObjectPropertyListenerBlock)] = []
    public private(set) var microphoneMuted = false
    private var timeline: CaptureTimeline?
    private var monitor: Timer?
    private var sleepObserver: NSObjectProtocol?
    private var gap: CaptureGap?
    private var transitioning = false
    private var stopRequested = false
    private var transitionWaiters: [CheckedContinuation<Void, Never>] = []
    private let hardware = SerializedHardwareLifecycle<CaptureHardwareSession>(label: "EchoVoice.audio.hardware")
    private let devices: CaptureDeviceProvider
    private static let microphoneRecoveryDebounce: Duration = .milliseconds(600)

    public private(set) var lifecycleState: CaptureLifecycleState = .idle

    public convenience init() { self.init(devices: .system) }
    init(devices: CaptureDeviceProvider) { self.devices = devices }

    public var currentTime: Double {
        timeline?.time(hostSeconds: AVAudioTime.seconds(forHostTime: mach_absolute_time())) ?? 0
    }

    public var isRecording: Bool { worker != nil }

    /// Available only while this controller owns the active capture epoch.
    /// Reading these values never opens another device or requests permission.
    public var recordingFormats: [CaptureAudioFormat] { activeFormats }

    /// Cancels an in-flight hardware transition without running Core Audio
    /// teardown on the caller. Call `stop()` to await complete cleanup.
    public func requestCancellation() {
        guard configuration != nil || transitioning else { return }
        stopRequested = true
        hardware.requestCancellation()
        if lifecycleState == .starting { lifecycleState = .stopping }
    }

    public func start(_ configuration: CaptureConfiguration, onEvent: @escaping @Sendable (CaptureEvent) -> Void) async throws {
        try Task.checkCancellation()
        guard configuration.recordingMode != .inPerson || (configuration.application == nil && configuration.microphone != nil) else { throw CaptureError.invalidConfiguration }
        guard self.configuration == nil, !transitioning, !stopRequested,
              configuration.initialOffset.isFinite, configuration.initialOffset >= 0,
              configuration.application != nil || configuration.microphone != nil,
              configuration.allowSingleSource || (configuration.application != nil && configuration.microphone != nil) else {
            throw CaptureError.invalidConfiguration
        }
        transitioning = true
        lifecycleState = .starting
        defer { finishTransition() }

        if configuration.microphone != nil {
            let authorized = await devices.requestMicrophone()
            guard authorized else {
                lifecycleState = .idle
                throw CaptureError.permission("Microphone access is required for the selected microphone. Enable it in System Settings → Privacy & Security → Microphone.")
            }
        }
        try Task.checkCancellation()
        guard !stopRequested else { throw CancellationError() }

        try FileManager.default.createDirectory(at: configuration.meetingDirectory, withIntermediateDirectories: true)
        self.configuration = configuration
        selectedMicrophone = configuration.microphone
        selectedApplication = configuration.application
        microphoneMuted = configuration.initialMicrophoneMuted
        desiredMicrophoneMuted = configuration.initialMicrophoneMuted
        microphoneRecoveryRequiresSelection = false
        if microphoneMuted { microphoneGate.close(at: mach_absolute_time()) } else { microphoneGate.open() }
        self.onEvent = onEvent
        timeline = CaptureTimeline(
            originSeconds: AVAudioTime.seconds(forHostTime: mach_absolute_time()),
            initialOffset: configuration.initialOffset
        )
        do {
            try checkDisk()
            try await beginEpoch()
        } catch {
            self.configuration = nil
            self.onEvent = nil
            timeline = nil
            activeFormats = []
            applicationProcessIDs = nil
            worker = nil
            selectedMicrophone = nil
            selectedApplication = nil
            microphoneQueue = nil
            lifecycleState = stopRequested ? .stopping : .idle
            throw error
        }
        lifecycleState = .recording
        if microphoneMuted {
            let gap = CaptureGap(id: UUID().uuidString, meetingID: configuration.meetingID,
                                 startTime: currentTime, endTime: nil, reason: "Microphone muted by user")
            microphoneGap = gap
            onEvent(.gap(gap))
            onEvent(.trackEvent(CaptureTrackEvent(id: gap.id, meetingID: gap.meetingID,
                                                 track: .microphone, startTime: gap.startTime,
                                                 endTime: nil, cause: .userMute, epochID: nil)))
        }
        installMonitor()
    }

    private func beginEpoch() async throws {
        guard let configuration, let timeline, let onEvent else { throw CaptureError.invalidConfiguration }
        let selectedMicrophone = self.selectedMicrophone
        let selectedApplication = self.selectedApplication
        let microphoneMuted = self.microphoneMuted
        let devices = self.devices
        let microphoneGate = self.microphoneGate
        let dormantMicrophoneFormat = lastMicrophoneFormat ?? configuration.expectedFormats?.first(where: { $0.track == .microphone })
        let microphoneConfigurationChanged: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in self?.scheduleMicrophoneRecovery() }
        }
        let failureHandler: @Sendable (String, Double?) -> Void = { [weak self] reason, time in
            Task { @MainActor [weak self] in await self?.interruptAfterTransition(reason, at: time) }
        }
        let trackFailureHandler: @Sendable (AudioTrack, String, Double?) -> Void = { [weak self] track, reason, time in
            Task { @MainActor [weak self] in self?.handleTrackFailure(track, reason: reason, at: time) }
        }

        let prepared = try await hardware.start(
            build: { token in
                let mic = try (microphoneMuted ? nil : selectedMicrophone).map { selected in
                    guard let current = try devices.microphones().first(where: { $0.id == selected.id }) else {
                        throw CaptureError.sourceUnavailable
                    }
                    let input = try devices.openMicrophone(current, microphoneConfigurationChanged)
                    microphoneGate.register(input.queue)
                    return input
                }
                try token.checkCancellation()
                let app = try selectedApplication.map { source in
                    guard let refreshed = try devices.applications().first(where: { $0.id == source.id }) else {
                        throw CaptureError.sourceUnavailable
                    }
                    return try devices.openApplication(refreshed)
                }
                try token.checkCancellation()

                var sources: [(AudioTrack, RealtimeBufferQueue)] = []
                if let mic { sources.append((.microphone, mic.queue)) }
                if let app { sources.append((.remote, app.queue)) }
                let formats = sources.map {
                    CaptureAudioFormat(track: $0.0, sampleRate: $0.1.format.sampleRate, channels: $0.1.format.channelCount)
                }
                // A muted device may be disconnected. Use its last known format
                // for conservative capacity checks; unmute checks the fresh format again.
                let preflightFormats = microphoneMuted ? formats + (dormantMicrophoneFormat.map { [$0] } ?? []) : formats
                try CaptureFormatValidation.verify(actual: preflightFormats, expected: configuration.expectedFormats)
                try configuration.runFormatPreflight(preflightFormats)
                let recording = try RecordingWorker(
                    configuration: configuration,
                    timeline: timeline,
                    sources: sources,
                    onEvent: onEvent,
                    onFailure: failureHandler,
                    onTrackFailure: trackFailureHandler
                )
                let session = CaptureHardwareSession(microphone: mic, application: app, worker: recording, formats: formats, devices: devices, microphoneGate: microphoneGate)
                try session.start(token)
                return (session, session.prepared)
            },
            discard: { $0.teardown() }
        )

        do {
            try Task.checkCancellation()
            guard !stopRequested else { throw CancellationError() }
        } catch {
            _ = await hardware.stop { session in
                session.teardown()
                return session.worker
            }
            throw error
        }

        worker = prepared.worker
        activeFormats = prepared.formats
        applicationProcessIDs = prepared.applicationProcessIDs
        microphoneQueue = prepared.microphoneQueue
        if let format = prepared.formats.first(where: { $0.track == .microphone }) { lastMicrophoneFormat = format }
        prepared.worker.start()
    }

    public func pause() async throws {
        let requestedMeetingID = configuration?.meetingID
        await waitWhileTransitioning()
        try Task.checkCancellation()
        guard !stopRequested else { throw CancellationError() }
        guard let requestedMeetingID, configuration?.meetingID == requestedMeetingID else {
            throw CaptureError.invalidConfiguration
        }
        if worker == nil {
            guard lifecycleState == .paused else { throw CaptureError.invalidConfiguration }
            return
        }
        transitioning = true
        lifecycleState = .stopping
        await endEpoch(reason: "Paused by user")
        lifecycleState = .paused
        finishTransition()
    }

    /// Closes the real-time admission gate before waiting for device teardown.
    /// The other selected track stays in the same recording worker and timeline.
    public func setMicrophoneMuted(_ muted: Bool, reason: String = "Microphone muted by user") async throws {
        guard configuration != nil, selectedMicrophone != nil, !stopRequested else {
            throw CaptureError.invalidConfiguration
        }
        desiredMicrophoneMuted = muted
        if muted { microphoneRecoveryTask?.cancel() }
        try await applyMicrophoneMute(muted, reason: reason, userRequest: true)
    }

    /// Ends the current microphone epoch without changing the user's mute
    /// intent. Configuration is committed before any new samples are admitted.
    public func reconfigureMicrophone(reason: String, configuration: () throws -> Void) async throws {
        try await applyMicrophoneMute(true, reason: reason)
        do {
            try configuration()
        } catch {
            try? await applyMicrophoneMute(false, reason: reason)
            throw error
        }
        // applyMicrophoneMute consults the latest user intent both before
        // opening hardware and after it returns; a concurrent mute wins.
        try await applyMicrophoneMute(false, reason: reason)
    }

    private func applyMicrophoneMute(_ muted: Bool, reason: String, userRequest: Bool = false) async throws {
        guard let requestedMeetingID = configuration?.meetingID, selectedMicrophone != nil, !stopRequested else {
            throw CaptureError.invalidConfiguration
        }
        if muted {
            let boundary = mach_absolute_time()
            microphoneGate.close(at: boundary)
            microphoneMuted = true
            if microphoneGap == nil {
                let start = currentTime
                let gap = CaptureGap(id: UUID().uuidString, meetingID: requestedMeetingID,
                                     startTime: start, endTime: nil, reason: reason)
                microphoneGap = gap
                onEvent?(.gap(gap))
                onEvent?(.trackEvent(CaptureTrackEvent(id: gap.id, meetingID: gap.meetingID,
                                                      track: .microphone, startTime: start, endTime: nil,
                                                      cause: userRequest ? .userMute : .deviceUnavailable, epochID: nil)))
            }
        }
        await waitWhileTransitioning()
        try Task.checkCancellation()
        guard configuration?.meetingID == requestedMeetingID, !stopRequested else { throw CancellationError() }
        if muted {
            if userRequest && !desiredMicrophoneMuted { return }
            if worker != nil, microphoneQueue != nil {
                transitioning = true
                defer { finishTransition() }
                try await hardware.withActive { session, token in
                    try token.checkCancellation()
                    try session.stopMicrophone()
                }
                microphoneQueue = nil
                activeFormats.removeAll { $0.track == .microphone }
            }
            return
        }
        guard !desiredMicrophoneMuted else { return }
        if !microphoneMuted, microphoneQueue != nil { return }
        guard let selectedMicrophone,
              let current = try devices.microphones().first(where: { $0.id == selectedMicrophone.id }) else {
            throw CaptureError.sourceUnavailable
        }
        microphoneGate.open()
        if worker != nil {
            transitioning = true
            defer { finishTransition() }
            let microphoneConfigurationChanged: @Sendable () -> Void = { [weak self] in
                Task { @MainActor [weak self] in self?.scheduleMicrophoneRecovery() }
            }
            let configuration = self.configuration!
            let otherFormats = activeFormats.filter { $0.track != .microphone }
            let queue = try await hardware.withActive { session, token in
                try token.checkCancellation()
                if session.microphone != nil { try session.stopMicrophone() }
                return try session.startMicrophone(device: current, onConfigurationChange: microphoneConfigurationChanged,
                                                  preflight: { try configuration.runFormatPreflight(otherFormats + [$0]) })
            }
            microphoneQueue = queue
            activeFormats.removeAll { $0.track == .microphone }
            activeFormats.append(CaptureAudioFormat(track: .microphone, sampleRate: queue.format.sampleRate,
                                                    channels: queue.format.channelCount))
            lastMicrophoneFormat = activeFormats.last
        }
        microphoneMuted = desiredMicrophoneMuted
        guard !microphoneMuted else { return }
        if let microphoneGap, let configuration {
            onEvent?(.gap(CaptureGap(id: microphoneGap.id, meetingID: configuration.meetingID,
                                     startTime: microphoneGap.startTime, endTime: currentTime,
                                     reason: microphoneGap.reason)))
            onEvent?(.trackEvent(CaptureTrackEvent(id: microphoneGap.id, meetingID: configuration.meetingID,
                                                  track: .microphone, startTime: microphoneGap.startTime,
                                                  endTime: currentTime,
                                                  cause: microphoneGap.reason == "Microphone muted by user" ? .userMute : .deviceUnavailable,
                                                  epochID: nil)))
            self.microphoneGap = nil
        }
    }

    public func changeMicrophone(uid: String) async throws {
        microphoneRecoveryRequiresSelection = false
        microphoneRecoveryAttempts = []
        try await replaceMicrophone(uid: uid)
    }

    private func replaceMicrophone(uid: String) async throws {
        guard configuration != nil, !transitioning, !stopRequested else { throw CaptureError.invalidConfiguration }
        guard let chosen = try devices.microphones().first(where: { $0.id == uid }) else {
            throw CaptureError.sourceUnavailable
        }
        if selectedMicrophone?.id == uid, microphoneMuted {
            selectedMicrophone = chosen
            if !desiredMicrophoneMuted { try await applyMicrophoneMute(false, reason: "Selected microphone restarted") }
            return
        }
        if selectedMicrophone == nil {
            selectedMicrophone = chosen
            microphoneMuted = true
            if worker != nil, !desiredMicrophoneMuted { try await applyMicrophoneMute(false, reason: "Selected microphone changed") }
            else { microphoneMuted = desiredMicrophoneMuted }
            return
        }
        let wasMuted = desiredMicrophoneMuted
        if !wasMuted, worker != nil { try await applyMicrophoneMute(true, reason: "Selected microphone changed") }
        selectedMicrophone = chosen
        if !wasMuted, worker != nil { try await applyMicrophoneMute(false, reason: "Selected microphone restarted") }
    }

    public func changeApplication(sourceID: String) async throws {
        guard let source = try devices.applications().first(where: { $0.id == sourceID }) else {
            throw CaptureError.sourceUnavailable
        }
        try await replaceApplication(with: source, reason: "Selected application changed")
    }

    private func replaceApplication(with source: AudioSource?, reason: String) async throws {
        guard configuration != nil, !transitioning, !stopRequested else { throw CaptureError.invalidConfiguration }
        selectedApplication = source
        guard worker != nil else { return }
        transitioning = true
        defer { finishTransition() }
        if applicationGap == nil, let configuration {
            let gap = CaptureGap(id: UUID().uuidString, meetingID: configuration.meetingID,
                                 startTime: currentTime, endTime: nil, reason: reason)
            applicationGap = gap
            onEvent?(.gap(gap))
            onEvent?(.trackEvent(CaptureTrackEvent(id: gap.id, meetingID: gap.meetingID,
                                                  track: .remote, startTime: gap.startTime,
                                                  endTime: nil, cause: .sourceChanged, epochID: nil)))
        }
        do {
            let next = try await hardware.withActive { session, token -> (RealtimeBufferQueue, Set<Int32>)? in
                try token.checkCancellation()
                try session.stopApplication()
                try token.checkCancellation()
                guard let source else { return nil }
                return try session.startApplication(source: source)
            }
            applicationProcessIDs = next?.1
            activeFormats.removeAll { $0.track == .remote }
            if let queue = next?.0 {
                activeFormats.append(CaptureAudioFormat(track: .remote, sampleRate: queue.format.sampleRate,
                                                        channels: queue.format.channelCount))
            }
            if next != nil, let applicationGap, let configuration {
                onEvent?(.gap(CaptureGap(id: applicationGap.id, meetingID: configuration.meetingID,
                                         startTime: applicationGap.startTime, endTime: currentTime,
                                         reason: applicationGap.reason)))
                onEvent?(.trackEvent(CaptureTrackEvent(id: applicationGap.id, meetingID: configuration.meetingID,
                                                      track: .remote, startTime: applicationGap.startTime,
                                                      endTime: currentTime, cause: .sourceChanged, epochID: nil)))
                self.applicationGap = nil
            }
        } catch {
            applicationProcessIDs = nil
            activeFormats.removeAll { $0.track == .remote }
            throw error
        }
    }

    public func resume() async throws {
        try Task.checkCancellation()
        guard configuration != nil, worker == nil, !transitioning, !stopRequested else {
            throw CaptureError.invalidConfiguration
        }
        transitioning = true
        lifecycleState = .starting
        defer { finishTransition() }
        do {
            try checkDisk()
            try await beginEpoch()
        } catch {
            lifecycleState = stopRequested ? .stopping : .paused
            throw error
        }
        if let existing = gap, let configuration {
            onEvent?(.gap(CaptureGap(id: existing.id, meetingID: configuration.meetingID, startTime: existing.startTime, endTime: currentTime, reason: existing.reason)))
        }
        gap = nil
        lifecycleState = .recording
    }

    public func stop() async {
        requestCancellation()
        await waitWhileTransitioning()
        transitioning = true
        lifecycleState = .stopping
        defer {
            stopRequested = false
            lifecycleState = .idle
            finishTransition()
        }
        monitor?.invalidate()
        monitor = nil
        if let sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver)
            self.sleepObserver = nil
        }
        await stopHardware()
        if let gap, let configuration {
            onEvent?(.gap(CaptureGap(id: gap.id, meetingID: configuration.meetingID, startTime: gap.startTime, endTime: currentTime, reason: gap.reason)))
        }
        if let microphoneGap, let configuration {
            onEvent?(.gap(CaptureGap(id: microphoneGap.id, meetingID: configuration.meetingID,
                                     startTime: microphoneGap.startTime, endTime: currentTime,
                                     reason: microphoneGap.reason)))
            onEvent?(.trackEvent(CaptureTrackEvent(id: microphoneGap.id, meetingID: configuration.meetingID,
                                                  track: .microphone, startTime: microphoneGap.startTime,
                                                  endTime: currentTime,
                                                  cause: microphoneGap.reason == "Microphone muted by user" ? .userMute : .deviceUnavailable,
                                                  epochID: nil)))
        }
        if let applicationGap, let configuration {
            onEvent?(.gap(CaptureGap(id: applicationGap.id, meetingID: configuration.meetingID,
                                     startTime: applicationGap.startTime, endTime: currentTime,
                                     reason: applicationGap.reason)))
            onEvent?(.trackEvent(CaptureTrackEvent(id: applicationGap.id, meetingID: configuration.meetingID,
                                                  track: .remote, startTime: applicationGap.startTime,
                                                  endTime: currentTime, cause: .sourceChanged, epochID: nil)))
        }
        applicationGap = nil
        microphoneGap = nil
        microphoneRecoveryTask?.cancel()
        microphoneRecoveryTask = nil
        microphoneRecoveryEarliest = nil
        microphoneRecoveryAttempts = []
        desiredMicrophoneMuted = false
        microphoneRecoveryRequiresSelection = false
        lastMicrophoneFormat = nil
        removeDeviceListeners()
        gap = nil
        configuration = nil
        selectedMicrophone = nil
        selectedApplication = nil
        microphoneMuted = false
        onEvent = nil
        timeline = nil
    }

    private func stopHardware() async {
        let recording = await hardware.stop { session in
            session.teardown()
            return session.worker
        }
        await recording?.finish()
        worker = nil
        activeFormats = []
        applicationProcessIDs = nil
        microphoneQueue = nil
    }

    private func endEpoch(reason: String, at time: Double? = nil) async {
        let interruptedAt = time ?? currentTime
        await stopHardware()
        if let configuration {
            let gap = CaptureGap(
                id: UUID().uuidString,
                meetingID: configuration.meetingID,
                startTime: interruptedAt,
                endTime: nil,
                reason: reason
            )
            self.gap = gap
            onEvent?(.gap(gap))
        }
    }

    private func interrupt(_ reason: String, at time: Double? = nil) async {
        guard worker != nil, !transitioning else { return }
        transitioning = true
        lifecycleState = .stopping
        await endEpoch(reason: reason, at: time)
        onEvent?(.interrupted(reason))
        lifecycleState = .paused
        finishTransition()
    }

    private func interruptAfterTransition(_ reason: String, at time: Double?) async {
        await waitWhileTransitioning()
        guard !stopRequested, worker?.hasTrack(.microphone) != true,
              worker?.hasTrack(.remote) != true else { return }
        await interrupt(reason, at: time)
    }

    private func handleTrackFailure(_ track: AudioTrack, reason: String, at time: Double?) {
        guard let configuration, worker != nil, !stopRequested else { return }
        let start = max(0, time ?? currentTime)
        let gap = CaptureGap(id: UUID().uuidString, meetingID: configuration.meetingID,
                             startTime: start, endTime: nil, reason: reason)
        if track == .microphone {
            if microphoneGap == nil { microphoneGap = gap; onEvent?(.gap(gap)) }
            scheduleMicrophoneRecovery()
        } else if track == .remote {
            if applicationGap == nil { applicationGap = gap; onEvent?(.gap(gap)) }
            Task { await inspectSources() }
        }
        onEvent?(.trackChanged(track, "\(reason). Other available audio continues; open Inputs if recovery does not succeed."))
    }

    private func installMonitor() {
        monitor = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.inspectSources() }
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.interrupt("The Mac went to sleep. Resume recording after waking.") }
        }
        // Speakers/headphones changing the default *output* must not tear down the mic.
        // Recover from device-list changes, AVAudioEngineConfigurationChange, or explicit Inputs.
        let selector = kAudioHardwarePropertyDevices
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in await self?.inspectSources() }
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address,
                                               DispatchQueue.main, listener) == noErr {
            deviceListeners.append((selector, listener))
        }
    }

    private func removeDeviceListeners() {
        Self.removeDeviceListeners(deviceListeners)
        deviceListeners.removeAll()
    }

    private nonisolated static func removeDeviceListeners(
        _ listeners: [(AudioObjectPropertySelector, AudioObjectPropertyListenerBlock)]
    ) {
        for (selector, listener) in listeners {
            var address = AudioObjectPropertyAddress(mSelector: selector,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address,
                                                   DispatchQueue.main, listener)
        }
    }

    private func scheduleMicrophoneRecovery() {
        guard worker != nil, !desiredMicrophoneMuted, !microphoneRecoveryRequiresSelection, !stopRequested else { return }
        microphoneRecoveryEarliest = .now.advanced(by: Self.microphoneRecoveryDebounce)
        guard microphoneRecoveryTask == nil else { return }
        microphoneRecoveryTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                if let earliest = self.microphoneRecoveryEarliest {
                    let remaining = earliest - ContinuousClock.now
                    if remaining > .zero {
                        do { try await Task.sleep(for: remaining) } catch { break }
                        continue
                    }
                }
                if await self.recoverMicrophoneRoute() { break }
                do { try await Task.sleep(for: .milliseconds(200)) } catch { break }
            }
            self?.microphoneRecoveryTask = nil
            self?.microphoneRecoveryEarliest = nil
        }
    }

    /// True means success or explicit user action is now required.
    private func recoverMicrophoneRoute() async -> Bool {
        guard worker != nil, !desiredMicrophoneMuted, !microphoneRecoveryRequiresSelection, !stopRequested,
              let selectedMicrophone else { return true }
        guard !transitioning else { return false }
        let now = Date().timeIntervalSinceReferenceDate
        microphoneRecoveryAttempts.removeAll { now - $0 > 5 }
        if microphoneRecoveryAttempts.count >= 3 {
            microphoneRecoveryRequiresSelection = true
            try? await applyMicrophoneMute(true, reason: "Selected microphone route changed repeatedly; choose an input to continue capturing your voice")
            onEvent?(.trackChanged(.microphone, "\(selectedMicrophone.name) could not be restarted after three attempts. Choose an input in Inputs to restore microphone capture."))
            return true
        }
        microphoneRecoveryAttempts.append(now)
        do {
            try await replaceMicrophone(uid: selectedMicrophone.id)
            onEvent?(.trackChanged(.microphone, "\(selectedMicrophone.name) changed audio format or route. Microphone capture restarted."))
            return true
        } catch {
            onEvent?(.trackChanged(.microphone, "\(selectedMicrophone.name) could not be restarted: \(error.localizedDescription). Choose an input in Inputs to restore microphone capture."))
            return false
        }
    }

    private func inspectSources() async {
        guard worker != nil, configuration != nil, !transitioning else { return }
        do {
            try checkDisk()
            if !desiredMicrophoneMuted, !microphoneRecoveryRequiresSelection, let selected = selectedMicrophone {
                if let current = try devices.microphones().first(where: { $0.id == selected.id }) {
                    if current.deviceID != selected.deviceID || worker?.hasTrack(.microphone) == false {
                        scheduleMicrophoneRecovery()
                    }
                } else {
                    microphoneRecoveryRequiresSelection = true
                    try await applyMicrophoneMute(true, reason: "Selected microphone \(selected.name) disconnected; choose an input to continue capturing your voice")
                    onEvent?(.trackChanged(.microphone, "\(selected.name) disconnected. Meeting audio is still recording; choose a microphone in Inputs."))
                    return
                }
            }
            if let selected = selectedApplication {
                let refreshed = try devices.applications().first(where: { $0.id == selected.id })
                if let refreshed {
                    if Set(refreshed.processIDs) != applicationProcessIDs || worker?.hasTrack(.remote) == false {
                        try await replaceApplication(with: refreshed, reason: "Selected application audio processes changed")
                        onEvent?(.trackChanged(.remote, "The selected application's audio processes changed. Its audio capture was refreshed."))
                    }
                } else if applicationProcessIDs != nil {
                    try await replaceApplication(with: nil, reason: "Selected application closed")
                    selectedApplication = selected
                    onEvent?(.trackChanged(.remote, "\(selected.name) closed. Microphone recording continues; choose the application again in Inputs when it returns."))
                }
            }
        } catch CaptureError.diskFull {
            await interrupt(CaptureError.diskFull.localizedDescription)
        } catch {
            onEvent?(.trackChanged(.remote, error.localizedDescription + " Other available audio keeps recording; open Inputs to retry."))
        }
    }

    private func checkDisk() throws {
        guard let configuration else { return }
        let values = try configuration.meetingDirectory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
        )
        let remaining = values.volumeAvailableCapacityForImportantUsage ?? Int64(values.volumeAvailableCapacity ?? 0)
        if remaining < 3_000_000_000 { onEvent?(.lowDisk(remaining)) }
        if remaining < 1_000_000_000 { throw CaptureError.diskFull }
    }

    /// Check-and-enqueue under one MainActor turn so finishTransition cannot
    /// drain between the predicate and the waiter registration.
    private func waitWhileTransitioning() async {
        while transitioning {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if transitioning {
                    transitionWaiters.append(continuation)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func finishTransition() {
        transitioning = false
        let waiters = transitionWaiters
        transitionWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    deinit {
        monitor?.invalidate()
        Self.removeDeviceListeners(deviceListeners)
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        hardware.stopDetached { session in
            session.teardown()
            let recording = session.worker
            Task { await recording.finish() }
        }
    }
}
