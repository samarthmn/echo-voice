import AVFoundation
import CoreAudio
import EchoAudioRing

/// Single producer / single consumer, preallocated C11 atomic frame ring.
/// No ARC-owned slot mutation, locks or allocations occur inside push/pop.
final class RealtimeBufferQueue: @unchecked Sendable {
    private let ring: OpaquePointer
    let format: AVAudioFormat
    let capacity: AVAudioFrameCount
    init(format: AVAudioFormat, capacity: AVAudioFrameCount = 8192, depth: Int? = nil) throws {
        self.format = format; self.capacity = capacity
        let buffers = format.isInterleaved ? 1 : format.channelCount
        let frames = depth.map { Int(capacity) * $0 } ?? max(Int(capacity), Int(ceil(format.sampleRate * 2)))
        guard frames > 0, frames <= Int(UInt32.max), let ring = ev_ring_create(UInt32(frames), format.streamDescription.pointee.mBytesPerFrame, buffers, UInt32(depth ?? frames)) else { throw CaptureError.unsupportedFormat }
        self.ring = ring
    }
    deinit { ev_ring_destroy(ring) }
    func push(_ input: UnsafePointer<AudioBufferList>, frames: AVAudioFrameCount, hostTime: UInt64) {
        _ = ev_ring_push(ring, input, frames, hostTime)
    }
    func pop(into output: AVAudioPCMBuffer) -> UInt64? {
        var frames: UInt32 = 0, host: UInt64 = 0
        guard ev_ring_pop(ring, output.mutableAudioBufferList, output.frameCapacity, &frames, &host) else { return nil }
        output.frameLength = frames
        return host
    }
    func mute(atHostTime hostTime: UInt64) { ev_ring_mute_at(ring, hostTime) }
    func unmute() { ev_ring_unmute(ring) }
    var muteHostTime: UInt64 { ev_ring_mute_host(ring) }
    var overflowCount: UInt64 { ev_ring_overflows(ring) }
    var invalidFrameCount: UInt64 { ev_ring_invalid(ring) }
    var hasDroppedAudio: Bool { overflowCount > 0 || invalidFrameCount > 0 }
}
