import Foundation
import AppKit
import AVFoundation
import CoreAudio
import AudioToolbox
import EchoCore

func checkAudio(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else { throw CaptureError.audio(operation, status) }
}
func audioValue<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, initial: T, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> T {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var result = initial
    var size = UInt32(MemoryLayout<T>.size)
    try withUnsafeMutablePointer(to: &result) { pointer in
        try checkAudio(AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer), "Read audio property")
    }
    return result
}
func audioObjects(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> [AudioObjectID] {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    try checkAudio(AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size), "Read audio list size")
    guard size > 0 else { return [] }
    var values = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    try values.withUnsafeMutableBytes { bytes in
        try checkAudio(AudioObjectGetPropertyData(object, &address, 0, nil, &size, bytes.baseAddress!), "Read audio list")
    }
    return values
}
func audioString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    let pointer = UnsafeMutablePointer<Unmanaged<CFString>?>.allocate(capacity: 1)
    pointer.initialize(to: nil)
    defer { pointer.deinitialize(count: 1); pointer.deallocate() }
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    try checkAudio(AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer), "Read audio name")
    return pointer.pointee?.takeRetainedValue() as String? ?? "Unknown"
}

struct AudioProcess {
    let objectID: AudioObjectID
    let pid: Int32
    let bundleID: String
}
func audioProcesses() throws -> [AudioProcess] {
    try audioObjects(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList).compactMap { object in
        guard let pid: Int32 = try? audioValue(object, kAudioProcessPropertyPID, initial: Int32(0)), pid != ProcessInfo.processInfo.processIdentifier else { return nil }
        return AudioProcess(objectID: object, pid: pid, bundleID: (try? audioString(object, kAudioProcessPropertyBundleID)) ?? "")
    }
}

/// Snapshot values keep app attribution deterministic and independently testable.
struct CaptureApplicationIdentity: Equatable {
    let pid: Int32
    let bundleID: String?
    let name: String
    let bundlePath: String?
    let isRegular: Bool
    var sourceID: String { bundleID ?? "pid:\(pid)" }
}

enum CaptureApplicationResolver {
    static func owner(pid: Int32, bundleID: String, executablePath: String?, applications: [CaptureApplicationIdentity]) -> CaptureApplicationIdentity? {
        let regular = applications.filter(\.isRegular)
        if let exact = regular.first(where: { $0.pid == pid }) { return exact }
        if let executablePath {
            let contained = regular.filter { app in
                guard let root = app.bundlePath else { return false }
                return executablePath.hasPrefix(root + "/")
            }
            // A nested regular app is a distinct selectable application. Attribute
            // its processes to the most specific proven bundle containment.
            if let length = contained.compactMap({ $0.bundlePath?.count }).max() {
                return unique(contained.filter { $0.bundlePath?.count == length })
            }
        }
        // Some HAL clients have no NSRunningApplication object. A unique regular
        // app namespace still identifies Chromium helpers. Accessory helpers are
        // NEVER candidates: shared WebKit bundle IDs can serve unrelated apps.
        guard !bundleID.isEmpty else { return nil }
        return unique(regular.filter { app in
            guard let ownerBundle = app.bundleID, !ownerBundle.isEmpty else { return false }
            return bundleID == ownerBundle || bundleID.hasPrefix(ownerBundle + ".")
        })
    }
    private static func unique(_ applications: [CaptureApplicationIdentity]) -> CaptureApplicationIdentity? {
        guard Set(applications.map(\.sourceID)).count == 1 else { return nil }
        return applications.min { $0.pid < $1.pid }
    }
}

public enum CapturePermissions {
    public static var microphoneStatus: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }
    public static var microphoneState: PermissionState {
        switch microphoneStatus {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }
    /// Call only from an explicit user action, such as Test Inputs or Start Recording.
    public static func requestMicrophone() async -> Bool {
        switch microphoneStatus {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await requestUndeterminedMicrophoneAccess()
        @unknown default:
            return false
        }
    }

    private static func requestUndeterminedMicrophoneAccess() async -> Bool {
        let request = PermissionRequest()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                request.install(continuation)
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    request.finish(granted)
                }
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 15) {
                    request.finish(false)
                }
            }
        } onCancel: {
            request.finish(false)
        }
    }
}

private final class PermissionRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var completedResult: Bool?

    func install(_ continuation: CheckedContinuation<Bool, Never>) {
        lock.lock()
        if let result = completedResult {
            lock.unlock()
            continuation.resume(returning: result)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func finish(_ result: Bool) {
        lock.lock()
        guard completedResult == nil else {
            lock.unlock()
            return
        }
        completedResult = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: result)
    }
}

@MainActor
extension AudioCaptureController {
    nonisolated public static func applications() throws -> [AudioSource] {
        let processes = try audioProcesses()
        let running = NSWorkspace.shared.runningApplications
        let identities = running.map { app in
            CaptureApplicationIdentity(pid: app.processIdentifier, bundleID: app.bundleIdentifier,
                                       name: app.localizedName ?? app.bundleIdentifier ?? "Application",
                                       bundlePath: app.bundleURL?.resolvingSymlinksInPath().standardizedFileURL.path,
                                       isRegular: app.activationPolicy == .regular)
        }
        var grouped: [String: (String, String?, [Int32])] = [:]
        for process in processes {
            let executable = NSRunningApplication(processIdentifier: process.pid)?.executableURL?.resolvingSymlinksInPath().standardizedFileURL.path
            guard let owner = CaptureApplicationResolver.owner(pid: process.pid, bundleID: process.bundleID, executablePath: executable, applications: identities) else { continue }
            let bundle = owner.bundleID
            let key = owner.sourceID
            var entry = grouped[key] ?? (owner.name, bundle, [])
            entry.2.append(process.pid); grouped[key] = entry
        }
        return grouped.map { AudioSource(id: $0.key, name: $0.value.0, bundleID: $0.value.1, processIDs: $0.value.2.sorted()) }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    nonisolated public static func microphones() throws -> [MicrophoneDevice] {
        let defaultDevice = try? audioValue(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, initial: AudioObjectID(0))
        return try audioObjects(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices).compactMap { device in
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return nil }
            let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { memory.deallocate() }
            guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, memory) == noErr else { return nil }
            let buffers = UnsafeMutableAudioBufferListPointer(memory.assumingMemoryBound(to: AudioBufferList.self))
            guard buffers.reduce(0, { $0 + $1.mNumberChannels }) > 0 else { return nil }
            let transport = try? audioValue(device, kAudioDevicePropertyTransportType, initial: UInt32(0))
            return MicrophoneDevice(id: try audioString(device, kAudioDevicePropertyDeviceUID), name: try audioString(device, kAudioObjectPropertyName), deviceID: device, isBuiltIn: transport == kAudioDeviceTransportTypeBuiltIn, isDefault: device == defaultDevice)
        }
    }
}
