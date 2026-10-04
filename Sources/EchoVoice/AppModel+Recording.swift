import Foundation
import SwiftUI
import AppKit
import AVFoundation
import EchoCore
import EchoCapture
import EchoRuntime
import EchoIntelligence

extension AppModel {
    func refreshSources() {
        do { sources = try AudioCaptureController.applications(); microphones = try AudioCaptureController.microphones() }
        catch { self.recordingError = error.localizedDescription }
    }

    func speakerSpans(for segment: TranscriptSegment, run: SpeakerGroupingRun) -> [SpeakerAttributionSpan] {
        (speakerTurnIndices[run.id] ?? SpeakerTurnIndex(run: run)).spans(segment: segment)
    }

    func refreshHealth() async {
        defer { runtimeChecked = true; drainProcessingQueue() }
        guard await service.installed else { health = nil; return }
        do { health = try await service.health() }
        catch { health = nil; setupProgress = error.localizedDescription }
    }

    func refreshPermissions() {
        let current = CapturePermissions.microphoneState
        if microphonePermission != current { microphonePermission = current }
    }

    func requestMicrophoneAccess() async {
        _ = await CapturePermissions.requestMicrophone()
        refreshPermissions()
    }

    /// There is no public preflight for selected-app audio, so record what capture actually observed.
    func recordMeetingAudio(_ state: PermissionState) {
        guard meetingAudioPermission != state else { return }
        meetingAudioPermission = state
        UserDefaults.standard.set(state.rawValue, forKey: Self.meetingAudioPermissionKey)
    }
    func observeMeetingAudioFailure(_ error: Error, application: AudioSource?) {
        guard application != nil, case CaptureError.audio(let operation, _) = error, operation.contains("selected-app audio tap") else { return }
        recordMeetingAudio(.denied)
    }

    func testInputs(application: AudioSource?, microphone: MicrophoneDevice?, singleSource: Bool, mode: RecordingMode = .online) async {
        guard !isRecording, !testingInputs, preparationTask == nil else { return }
        cancellingPreparation = false
        let task = Task { await performInputTest(application: mode == .inPerson ? nil : application, microphone: microphone, singleSource: mode == .inPerson || singleSource, mode: mode) }
        preparationTask = task
        await task.value
        preparationTask = nil; cancellingPreparation = false
    }

    /// Cancellation is immediate; cleanup stays on the serialized hardware lane.
    /// Keep the sheet open until cleanup completes so another start cannot race it.
    func cancelPreparation() {
        guard preparationTask != nil else { return }
        cancellingPreparation = true
        preparationTask?.cancel()
        if let inputTestCapture { inputTestCapture.requestCancellation() }
        else { capture.requestCancellation() }
    }

    func performInputTest(application: AudioSource?, microphone: MicrophoneDevice?, singleSource: Bool, mode: RecordingMode) async {
        testingInputs = true; inputTestPassed = false; microphoneLevel = 0; remoteLevel = 0
        let id = UUID().uuidString
        let directory = paths.root.appendingPathComponent("input-tests").appendingPathComponent(id)
        let testCapture = AudioCaptureController()
        inputTestCapture = testCapture
        defer { testingInputs = false; inputTestCapture = nil; try? FileManager.default.removeItem(at: directory) }
        do {
            try Task.checkCancellation()
            try await testCapture.start(.init(meetingID: id, meetingDirectory: directory, application: application, microphone: microphone, allowSingleSource: singleSource, recordingMode: mode)) { [weak self] event in
                if case .level(let track, let value) = event { Task { @MainActor in
                    if track == .remote { self?.remoteLevel = value; if value > Self.audibleLevel { self?.recordMeetingAudio(.granted) } } else { self?.microphoneLevel = value }
                } }
            }
            refreshPermissions()
            try await Task.sleep(nanoseconds: 5_000_000_000)
            let formats = testCapture.recordingFormats
            guard testCapture.isRecording,
                  formats.count == (application == nil ? 0 : 1) + (microphone == nil ? 0 : 1) else {
                throw RuntimeError.service("The input test was interrupted. Test the selected sources again.")
            }
            _ = try CaptureStorageEstimate.calculate(formats: formats, echoCancellation: false)
            await testCapture.stop()
            try Task.checkCancellation()
            inputTestPassed = true
        } catch is CancellationError { await testCapture.stop(); status = "Input test cancelled" }
        catch { await testCapture.stop(); refreshPermissions(); observeMeetingAudioFailure(error, application: application); self.recordingError = error.localizedDescription }
    }

    func startMeeting(_ request: RecordingRequest) async {
        await startMeeting(title: request.title, application: request.application, microphone: request.microphone,
            singleSource: request.singleSource, echoCancellation: request.acousticMode == .speakerphone,
            consent: request.consent, speechModel: request.speechModel, resumeID: request.resumeID,
            mode: request.mode, microphoneMuted: request.microphoneMuted,
            liveTranscription: request.liveTranscription, speakerModelID: request.speakerModelID)
    }

    func startMeeting(title: String, application: AudioSource?, microphone: MicrophoneDevice?, singleSource: Bool, echoCancellation: Bool, consent: Bool, speechModel: SpeechRecognitionModel = .whisper, resumeID: String? = nil, mode: RecordingMode = .online, microphoneMuted: Bool = false, liveTranscription: Bool = true, speakerModelID: String? = nil) async {
        guard preparationTask == nil else { return }
        cancellingPreparation = false
        let task = Task { await performStartMeeting(title: title, application: mode == .inPerson ? nil : application, microphone: microphone, singleSource: mode == .inPerson || singleSource, echoCancellation: mode == .online && echoCancellation, consent: consent, speechModel: speechModel, resumeID: resumeID, mode: mode, microphoneMuted: microphoneMuted, liveTranscription: liveTranscription, speakerModelID: speakerModelID) }
        preparationTask = task
        await task.value
        preparationTask = nil; cancellingPreparation = false
    }

    func performStartMeeting(title: String, application: AudioSource?, microphone: MicrophoneDevice?, singleSource: Bool, echoCancellation: Bool, consent: Bool, speechModel: SpeechRecognitionModel, resumeID: String?, mode: RecordingMode, microphoneMuted: Bool, liveTranscription: Bool, speakerModelID: String?) async {
        if let reason = startBlockedReason(consent: consent) { self.recordingError = reason; return }
        if let resumeID, assetWorkBlocked(resumeID) { return }
        guard let store, let processor else { return }
        changingRecording = true
        defer { changingRecording = false; if !isRecording { resumeIdleWork() } }
        do {
            try Task.checkCancellation()
            let values = try paths.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
            guard let capacity = values.volumeAvailableCapacityForImportantUsage ?? values.volumeAvailableCapacity.map({ Int64($0) }) else {
                throw RuntimeError.service("Available disk space could not be checked. Check the recording location and try again.")
            }
            compactionTask?.cancel()
            await compactionTask?.value
            compactionTask = nil
            // The persisted queue retains older work while capture takes priority.
            let previous = processingTask
            processingGeneration += 1
            processingTask?.cancel()
            processingID = nil
            let activation = activationTask
            let runtimeSetup = activeDownload == nil && setupBusy ? setupTask : nil
            let handoff = Task { await activation?.value; await runtimeSetup?.value; await processor.cancel(); await previous?.value }
            let handoffGeneration = processingGeneration
            Task { [weak self] in
                await handoff.value
                guard let self, self.processingGeneration == handoffGeneration else { return }
                self.inferenceHandoff = nil
                self.resumeIdleWork()
            }
            inferenceHandoff = handoff
            try Task.checkCancellation()
            stopPlayback()
            let effectiveAcousticMode: CaptureAcousticMode = echoCancellation && application != nil && microphone != nil ? .speakerphone : .headphones
            var meeting: Meeting
            var offset = 0.0
            let effectiveMicrophoneMuted: Bool
            if let resumeID, let recovered = try store.meeting(id: resumeID) {
                await handoff.value
                guard recovered.state == .interrupted else { throw RuntimeError.service("Only an interrupted recording can be resumed.") }
                try store.finishQueuedProcessing(meetingID: resumeID)
                let saved = try store.captureSessionSettings(meetingID: resumeID)
                let resumed = try CaptureResumePolicy.validate(meeting: recovered, saved: saved,
                                                               mode: mode, applicationID: application?.id,
                                                               microphoneUID: microphone?.id,
                                                               acousticMode: effectiveAcousticMode)
                meeting = recovered; offset = max(Date().timeIntervalSince(meeting.startedAt), try store.chunks(meetingID: resumeID).map { $0.startTime + $0.duration }.max() ?? 0)
                effectiveMicrophoneMuted = resumed.microphoneMuted
                let previousEnd = try store.chunks(meetingID: resumeID).map { $0.startTime + $0.duration }.max() ?? 0
                try store.addGap(.init(id: UUID().uuidString, meetingID: resumeID, startTime: previousEnd, endTime: offset, reason: "Recording recovered after an interruption"))
                meeting.state = .recording; meeting.endedAt = nil; try store.updateMeeting(meeting)
            } else {
                effectiveMicrophoneMuted = microphoneMuted
                meeting = Meeting(id: UUID().uuidString, title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled meeting" : title, startedAt: Date(), endedAt: nil, state: .recording, language: "en", sourceName: mode == .inPerson ? "Room microphone" : application?.name ?? "Microphone only", usesEchoCancellation: echoCancellation && application != nil && microphone != nil, transcriptRevision: 0, speechModel: speechModel, recordingMode: mode)
                try store.createMeeting(meeting)
                try store.setInitialLiveTranscriptionPolicy(meetingID: meeting.id, enabled: liveTranscription)
                var configuration = try processingConfiguration(speech: speechModel, speakerModelID: speakerModelID)
                configuration.recordingMode = mode
                try store.setConfiguration(meetingID: meeting.id, configuration: configuration)
            }
            let meetingID = meeting.id
            let policy = try store.liveTranscriptionPolicy(meetingID: meetingID)
            let sessionSettings = CaptureSessionSettings(microphoneUID: microphone?.id, applicationID: application?.id,
                                                         microphoneMuted: effectiveMicrophoneMuted,
                                                         acousticMode: effectiveAcousticMode)
            try store.setCaptureSessionSettings(meetingID: meetingID, settings: sessionSettings)
            recordingID = meetingID; selectedID = meetingID; isPaused = false; waitingForRemoteAudio = false
            recordingMicrophoneUID = microphone?.id; recordingApplicationID = application?.id
            do {
                let useAEC = echoCancellation && application != nil && microphone != nil
                try await capture.start(.init(meetingID: meetingID, meetingDirectory: paths.meetingDirectory(meetingID), application: application, microphone: microphone, allowSingleSource: singleSource, initialOffset: offset, recordingMode: mode, initialMicrophoneMuted: effectiveMicrophoneMuted, formatPreflight: { formats in
                    let estimate = try CaptureStorageEstimate.calculate(formats: formats, echoCancellation: useAEC).requiredBytes
                    guard capacity >= estimate else { throw RuntimeError.service("An eight-hour session needs approximately \(ByteCountFormatter.string(fromByteCount: estimate, countStyle: .file)) free. Free space before recording.") }
                })) { [weak self, store] event in
                    // Persist on the recording writer's non-real-time queue before it acknowledges the chunk.
                    do {
                        switch event {
                        case .chunk(let chunk):
                            if chunk.track == .microphone,
                               try store.microphoneProcessingEpoch(meetingID: chunk.meetingID, epochID: chunk.epochID) == nil {
                                let mode = try store.captureSessionSettings(meetingID: chunk.meetingID).acousticMode
                                let asset = try store.paths.resolveMeetingAsset(meetingID: chunk.meetingID, relativePath: chunk.relativePath)
                                let channels = try AVAudioFile(forReading: asset).fileFormat.channelCount
                                try store.saveMicrophoneProcessingEpoch(MicrophoneProcessingEpoch(
                                    meetingID: chunk.meetingID, epochID: chunk.epochID,
                                    startTime: chunk.startTime, sampleRate: chunk.sampleRate,
                                    channels: channels, acousticMode: mode
                                ))
                            }
                            try store.addChunk(chunk)
                        case .gap(let gap): try store.addGap(gap)
                        case .trackEvent(let trackEvent): try store.saveCaptureTrackEvent(trackEvent)
                        default: break
                        }
                        Task { @MainActor in self?.handleCapture(event) }
                    } catch { Task { @MainActor in self?.error = error.localizedDescription; await self?.pauseForStorageFailure() } }
                }
                try Task.checkCancellation()
            } catch { await capture.stop(); refreshPermissions(); observeMeetingAudioFailure(error, application: application); meeting.state = .interrupted; try store.updateMeeting(meeting); recordingID = nil; throw error }
            refreshPermissions()
            self.microphoneMuted = capture.microphoneMuted
            liveTranscriptionPolicy = policy
            self.acousticMode = sessionSettings.acousticMode
            UserDefaults.standard.set(mode.rawValue, forKey: "lastRecordingMode")
            recording.message = ""
            showNewMeeting = false; status = "Recording locally"; reload()
            liveStartTask = Task { [weak self] in
                await handoff.value
                guard let self, self.processingGeneration == handoffGeneration else { return }
                self.inferenceHandoff = nil
                guard !Task.isCancelled, self.recordingID == meetingID, !self.stoppingRecording else { return }
                await processor.startLive(meetingID: meetingID) { [weak self] message in
                    Task { @MainActor in
                        guard self?.recordingID == meetingID else { return }
                        self?.processingEvents[meetingID] = ProcessingEvent(meetingID: meetingID, stage: .transcribing, message: message)
                        self?.scheduleRefresh()
                    }
                }
            }
        } catch is CancellationError { await capture.stop(); status = "Start cancelled. Any saved audio is retained."; reload() }
        catch { self.recordingError = error.localizedDescription; reload() }
    }

    func handleCapture(_ event: CaptureEvent) {
        switch event {
        case .level(let track, let value):
            let now = ProcessInfo.processInfo.systemUptime
            if track == .remote {
                if value > Self.audibleLevel { recordMeetingAudio(.granted) }
                if now - lastRemoteMeterAt >= 0.1 { remoteLevel = value; lastRemoteMeterAt = now }
            } else if now - lastMicrophoneMeterAt >= 0.1 {
                microphoneLevel = value; lastMicrophoneMeterAt = now
            }
        case .chunk: scheduleRefresh()
        case .gap(let gap):
            if gap.reason.hasPrefix("Waiting for the selected application") { waitingForRemoteAudio = gap.endTime == nil }
            scheduleRefresh()
        case .trackEvent: scheduleRefresh()
        case .interrupted(let reason), .sourceChanged(let reason): isPaused = true; waitingForRemoteAudio = false; recording.message = reason; setRecordingState(.interrupted)
        case .trackChanged(let track, let reason):
            recording.message = reason; refreshSources(); scheduleRefresh()
            if track == .microphone { microphoneMuted = capture.microphoneMuted }
        case .lowDisk(let remaining): recording.message = "Low space: \(ByteCountFormatter.string(fromByteCount: remaining, countStyle: .file)) available"; if remaining < 1_000_000_000 { Task { await stopRecording() } }
        }
    }

    func pauseForStorageFailure() async {
        do {
            try await capture.pause()
            isPaused = true
            setRecordingState(.interrupted)
        } catch {
            self.recordingError = "Could not pause recording after a storage failure: \(error.localizedDescription)"
        }
    }
    func setRecordingState(_ state: MeetingState) { guard let id = recordingID, var meeting = try? store?.meeting(id: id) else { return }; meeting.state = state; try? store?.updateMeeting(meeting); reload() }
    func scheduleRefresh() { guard refreshTask == nil else { return }; refreshTask = Task { try? await Task.sleep(nanoseconds: 300_000_000); reload(); reloadDetail(); refreshTask = nil } }

    func togglePause() async {
        guard let id = recordingID, !changingRecording, !stoppingRecording else { return }
        changingRecording = true
        defer { if recordingID == id, !stoppingRecording { changingRecording = false } }
        do {
            let wasPaused = isPaused
            if wasPaused { try await capture.resume() } else { try await capture.pause() }
            guard recordingID == id, !stoppingRecording else { return }
            isPaused = !wasPaused
            status = wasPaused ? "Recording locally" : "Paused"
            setRecordingState(wasPaused ? .recording : .paused)
        } catch { if recordingID == id, !stoppingRecording { self.recordingError = error.localizedDescription } }
    }

    func stopLiveTranscription() async {
        guard let id = recordingID, liveTranscriptionPolicy?.admitsLiveRecognition == true,
              let processor else { return }
        do {
            try await processor.stopLiveTranscription(meetingID: id, effectiveTime: capture.currentTime)
            liveTranscriptionPolicy = try store?.liveTranscriptionPolicy(meetingID: id)
            status = "Live transcription stopped. Remaining speech will be transcribed after the meeting."
        } catch { self.recordingError = error.localizedDescription }
    }

    func setMicrophoneMuted(_ muted: Bool) async {
        guard let id = recordingID, let store else { return }
        do {
            try await capture.setMicrophoneMuted(muted)
            microphoneMuted = capture.microphoneMuted
            var settings = try store.captureSessionSettings(meetingID: id)
            settings.microphoneMuted = capture.microphoneMuted
            try store.setCaptureSessionSettings(meetingID: id, settings: settings)
            microphoneMuted = capture.microphoneMuted
            microphoneLevel = muted ? 0 : microphoneLevel
            status = muted ? "Microphone muted in Echo Voice. Meeting audio continues." : "Microphone recording resumed."
        } catch {
            microphoneMuted = capture.microphoneMuted
            self.recordingError = error.localizedDescription
        }
    }

    func changeMicrophone(uid: String) async {
        guard let id = recordingID, let store else { return }
        do {
            try await capture.changeMicrophone(uid: uid)
            recordingMicrophoneUID = uid
            microphoneMuted = capture.microphoneMuted
            var settings = try store.captureSessionSettings(meetingID: id)
            settings.microphoneUID = uid
            settings.microphoneMuted = capture.microphoneMuted
            try store.setCaptureSessionSettings(meetingID: id, settings: settings)
            recordingMicrophoneUID = uid
            microphoneMuted = capture.microphoneMuted
            status = "Microphone input changed."
        } catch {
            microphoneMuted = capture.microphoneMuted
            self.recordingError = "Could not switch microphone: " + error.localizedDescription
        }
    }

    func changeApplication(sourceID: String) async {
        guard let id = recordingID, let store else { return }
        do {
            try await capture.changeApplication(sourceID: sourceID)
            recordingApplicationID = sourceID
            var settings = try store.captureSessionSettings(meetingID: id)
            settings.applicationID = sourceID
            try store.setCaptureSessionSettings(meetingID: id, settings: settings)
            recordingApplicationID = sourceID
            status = "Selected meeting application changed."
        } catch { self.recordingError = "Could not switch meeting application: " + error.localizedDescription }
    }

    func setAcousticMode(_ mode: CaptureAcousticMode) async {
        guard let id = recordingID, let store, (try? store.meeting(id: id))?.recordingMode == .online else { return }
        do {
            var settings = try store.captureSessionSettings(meetingID: id)
            guard settings.acousticMode != mode else { return }
            guard mode != .speakerphone || (settings.microphoneUID != nil && settings.applicationID != nil) else {
                throw EchoCoreError.invalidValue("Select a microphone and meeting application before enabling Speakerphone")
            }
            let commitMode = {
                // Source and mute choices may have changed while teardown waited.
                var current = try store.captureSessionSettings(meetingID: id)
                current.acousticMode = mode
                current.microphoneMuted = self.capture.microphoneMuted
                try store.setCaptureSessionSettings(meetingID: id, settings: current)
                self.acousticMode = mode
            }
            if recordingMicrophoneUID != nil {
                try await capture.reconfigureMicrophone(reason: "Acoustic processing mode changed", configuration: commitMode)
            } else { try commitMode() }
            guard recordingID == id, !stoppingRecording else { return }
            microphoneMuted = capture.microphoneMuted
            settings = try store.captureSessionSettings(meetingID: id)
            settings.microphoneMuted = capture.microphoneMuted
            try store.setCaptureSessionSettings(meetingID: id, settings: settings)
            status = mode == .speakerphone ? "Speakerphone processing will apply to new microphone audio." : "Headphones mode will use new raw microphone audio."
        } catch {
            microphoneMuted = capture.microphoneMuted
            self.recordingError = "Could not change acoustic mode: " + error.localizedDescription
        }
    }

    func stopRecording(finalize: Bool = true) async {
        guard let id = recordingID, !stoppingRecording else { return }
        stoppingRecording = true
        defer { stoppingRecording = false }
        capture.requestCancellation()
        changingRecording = true

        liveStartTask?.cancel()
        await capture.stop()
        await liveStartTask?.value
        liveStartTask = nil
        // Finalize durable audio before starting post-processing.
        await processor?.stopLive()
        recording.message = ""
        recordingID = nil; isPaused = false; microphoneLevel = 0; remoteLevel = 0; waitingForRemoteAudio = false
        liveTranscriptionPolicy = nil
        microphoneMuted = false; recordingMicrophoneUID = nil; recordingApplicationID = nil; showInputsPanel = false
        acousticMode = .headphones
        do { try store?.queueFinishedRecording(meetingID: id, endedAt: Date()) }
        catch { self.recordingError = error.localizedDescription }
        reload(); reloadDetail()
        changingRecording = false
        if finalize { resumeIdleWork() }
    }

}
