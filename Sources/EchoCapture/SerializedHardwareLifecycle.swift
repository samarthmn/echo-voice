import Foundation

/// A cancellation flag that can be checked between individual hardware calls.
/// Cancellation never destroys hardware itself; teardown remains confined to the
/// lifecycle queue.
final class HardwareCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func checkCancellation() throws {
        if isCancelled { throw CancellationError() }
    }
}

/// Owns one hardware session on a dedicated serial queue. Creation, late-start
/// cleanup, normal stop, and destruction all execute on that same queue.
final class SerializedHardwareLifecycle<Hardware: Sendable>: @unchecked Sendable {
    private enum StateError: Error { case busy }

    private let queue: DispatchQueue
    private let stateLock = NSLock()
    private var currentToken: HardwareCancellationToken?

    // Accessed only by `queue`.
    private var active: Hardware?

    init(label: String) {
        queue = DispatchQueue(label: label, qos: .userInitiated)
    }

    func start<Value: Sendable>(
        build: @escaping @Sendable (HardwareCancellationToken) throws -> (Hardware, Value),
        discard: @escaping @Sendable (Hardware) -> Void
    ) async throws -> Value {
        let token = HardwareCancellationToken()
        try register(token)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    do {
                        try token.checkCancellation()
                        let (hardware, value) = try build(token)
                        guard !token.isCancelled else {
                            discard(hardware)
                            unregister(token)
                            continuation.resume(throwing: CancellationError())
                            return
                        }
                        active = hardware
                        continuation.resume(returning: value)
                    } catch {
                        unregister(token)
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            token.cancel()
        }
    }

    /// May be called synchronously from a UI cancellation action. The active or
    /// in-flight operation observes it without doing teardown on the caller.
    func requestCancellation() {
        stateLock.lock()
        let token = currentToken
        stateLock.unlock()
        token?.cancel()
    }

    /// Runs an in-session device transition on the same queue as start and stop.
    func withActive<Value: Sendable>(
        _ operation: @escaping @Sendable (Hardware, HardwareCancellationToken) throws -> Value
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard let active else { continuation.resume(throwing: StateError.busy); return }
                stateLock.lock()
                let token = currentToken
                stateLock.unlock()
                guard let token else { continuation.resume(throwing: StateError.busy); return }
                do {
                    try token.checkCancellation()
                    let value = try operation(active, token)
                    try token.checkCancellation()
                    continuation.resume(returning: value)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// Waits behind any in-flight start, then tears down at most one active
    /// hardware session on the lifecycle queue.
    func stop<Value: Sendable>(
        _ teardown: @escaping @Sendable (Hardware) -> Value
    ) async -> Value? {
        requestCancellation()
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard let hardware = active else {
                    clearToken()
                    continuation.resume(returning: nil)
                    return
                }
                active = nil
                let value = teardown(hardware)
                clearToken()
                continuation.resume(returning: value)
            }
        }
    }

    /// Used only as a deinitialization safety net when an owner is released
    /// without awaiting its public stop path.
    func stopDetached(_ teardown: @escaping @Sendable (Hardware) -> Void) {
        requestCancellation()
        queue.async { [self] in
            if let hardware = active {
                active = nil
                teardown(hardware)
            }
            clearToken()
        }
    }

    private func register(_ token: HardwareCancellationToken) throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard currentToken == nil else { throw StateError.busy }
        currentToken = token
    }

    private func unregister(_ token: HardwareCancellationToken) {
        stateLock.lock()
        if currentToken === token { currentToken = nil }
        stateLock.unlock()
    }

    private func clearToken() {
        stateLock.lock()
        currentToken = nil
        stateLock.unlock()
    }
}
