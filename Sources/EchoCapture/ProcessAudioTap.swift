import Foundation
import CoreAudio
import AVFoundation

final class ProcessAudioTap {
    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0
    private var ioProc: AudioDeviceIOProcID?
    private var started = false
    let queue: RealtimeBufferQueue
    let processIDs: Set<Int32>
    init(source: AudioSource) throws {
        let processes = try audioProcesses().filter { source.processIDs.contains($0.pid) }
        guard !processes.isEmpty else { throw CaptureError.sourceUnavailable }
        processIDs = Set(processes.map(\.pid))
        let description = CATapDescription(stereoMixdownOfProcesses: processes.map(\.objectID))
        description.name = "Echo Voice selected application"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        description.isExclusive = false
        var createdTap: AudioObjectID = 0
        try checkAudio(AudioHardwareCreateProcessTap(description, &createdTap), "Create selected-app audio tap")
        tapID = createdTap
        do {
            var asbd = try audioValue(createdTap, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())
            guard let format = AVAudioFormat(streamDescription: &asbd), asbd.mFormatID == kAudioFormatLinearPCM else { throw CaptureError.unsupportedFormat }
            queue = try RealtimeBufferQueue(format: format)
        } catch { AudioHardwareDestroyProcessTap(createdTap); throw error }
        do {
            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Echo Voice private capture",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                // A nonzero value makes AudioDeviceStart wait for the tapped
                // process's first audio. Waiting is represented in our worker,
                // never as a blocking hardware-start call on the UI thread.
                kAudioAggregateDeviceTapAutoStartKey: false,
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]]
            ]
            try checkAudio(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "Create private audio aggregate")
            let ring = queue
            let bytesPerFrame = formatBytesPerFrame
            try checkAudio(AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregateID, nil) { _, input, inputTime, _, _ in
                let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
                guard let first = list.first, bytesPerFrame > 0 else { return }
                let frames = first.mDataByteSize / bytesPerFrame
                ring.push(input, frames: frames, hostTime: inputTime.pointee.mFlags.contains(.hostTimeValid) ? inputTime.pointee.mHostTime : 0)
            }, "Create audio capture callback")
        } catch { teardown(); throw error }
    }
    private var formatBytesPerFrame: UInt32 { queue.format.streamDescription.pointee.mBytesPerFrame }
    func start() throws {
        guard !started else { return }
        try checkAudio(AudioDeviceStart(aggregateID, ioProc), "Start selected-app capture")
        started = true
    }
    func stop() {
        guard started, aggregateID != 0, let ioProc else { return }
        AudioDeviceStop(aggregateID, ioProc)
        started = false
    }
    func teardown() {
        stop()
        if let ioProc { AudioDeviceDestroyIOProcID(aggregateID, ioProc); self.ioProc = nil }
        if aggregateID != 0 { AudioHardwareDestroyAggregateDevice(aggregateID); aggregateID = 0 }
        if tapID != 0 { AudioHardwareDestroyProcessTap(tapID); tapID = 0 }
    }
    deinit { teardown() }
}

final class MicrophoneCapture {
    private let engine = AVAudioEngine()
    private var configurationObserver: NSObjectProtocol?
    private var tapInstalled = false
    private var started = false
    let queue: RealtimeBufferQueue
    init(device: MicrophoneDevice, onConfigurationChange: (@Sendable () -> Void)? = nil) throws {
        let input = engine.inputNode
        guard let unit = input.audioUnit else { throw CaptureError.sourceUnavailable }
        var id = AudioDeviceID(device.deviceID)
        try checkAudio(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size)), "Select microphone")
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { throw CaptureError.sourceUnavailable }
        queue = try RealtimeBufferQueue(format: format)
        let ring = queue
        // Voice processing is intentionally absent: this is the canonical raw track.
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, time in
            ring.push(buffer.audioBufferList, frames: buffer.frameLength, hostTime: time.isHostTimeValid ? time.hostTime : 0)
        }
        tapInstalled = true
        if let onConfigurationChange {
            configurationObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
            ) { _ in onConfigurationChange() }
        }
    }
    func start() throws {
        guard !started else { return }
        engine.prepare()
        try engine.start()
        started = true
    }
    func stop() {
        guard started else { return }
        engine.stop()
        started = false
    }
    func teardown() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        stop()
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
    }
    deinit { teardown() }
}
