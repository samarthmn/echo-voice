import Foundation

/// Hardware stays owned by the serialized lifecycle queue. These boundaries
/// let lifecycle tests exercise durable recording without opening real devices.
protocol CaptureMicrophoneInput: AnyObject {
    var queue: RealtimeBufferQueue { get }
    func start() throws
    func teardown()
}
protocol CaptureApplicationInput: AnyObject {
    var queue: RealtimeBufferQueue { get }
    var processIDs: Set<Int32> { get }
    func start() throws
    func stop()
    func teardown()
}
extension MicrophoneCapture: CaptureMicrophoneInput {}
extension ProcessAudioTap: CaptureApplicationInput {}

struct CaptureDeviceProvider: Sendable {
    var microphones: @Sendable () throws -> [MicrophoneDevice]
    var applications: @Sendable () throws -> [AudioSource]
    var requestMicrophone: @Sendable () async -> Bool
    var openMicrophone: @Sendable (MicrophoneDevice, @escaping @Sendable () -> Void) throws -> any CaptureMicrophoneInput
    var openApplication: @Sendable (AudioSource) throws -> any CaptureApplicationInput

    static let system = CaptureDeviceProvider(
        microphones: { try AudioCaptureController.microphones() },
        applications: { try AudioCaptureController.applications() },
        requestMicrophone: { await CapturePermissions.requestMicrophone() },
        openMicrophone: { try MicrophoneCapture(device: $0, onConfigurationChange: $1) },
        openApplication: { try ProcessAudioTap(source: $0) }
    )
}
