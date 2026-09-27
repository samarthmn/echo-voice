import Foundation

/// Control-plane synchronization only. Audio callbacks still read their ring's
/// C11 atomic gate, with no allocations or locks. Register before hardware starts
/// so a mute also closes a microphone being opened on the lifecycle queue.
final class MicrophoneAdmissionGate: @unchecked Sendable {
    private final class Entry {
        weak var queue: RealtimeBufferQueue?
        init(_ queue: RealtimeBufferQueue) { self.queue = queue }
    }
    private let lock = NSLock()
    private var queues: [Entry] = []
    private var closedAt: UInt64 = 0

    func register(_ queue: RealtimeBufferQueue) {
        lock.lock(); defer { lock.unlock() }
        queues.removeAll { $0.queue == nil }
        queues.append(Entry(queue))
        if closedAt != 0, queue.muteHostTime == 0 { queue.mute(atHostTime: closedAt) }
    }
    func close(at host: UInt64) {
        lock.lock(); defer { lock.unlock() }
        if closedAt == 0 { closedAt = host == 0 ? 1 : host }
        for entry in queues {
            if let queue = entry.queue, queue.muteHostTime == 0 { queue.mute(atHostTime: closedAt) }
        }
    }
    /// Opening admits a fresh epoch; it never reopens an old queue across a gap.
    func open() { lock.lock(); closedAt = 0; lock.unlock() }
}
