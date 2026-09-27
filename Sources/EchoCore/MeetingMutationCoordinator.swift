import Foundation

public enum MeetingOperationAccess: Sendable, Equatable { case read, exclusive }

public struct MeetingOperationLease: Sendable {
    fileprivate let coordinator: MeetingMutationCoordinator
    fileprivate let meetingID: String
    fileprivate let id: UUID

    public func release() async { await coordinator.release(meetingID: meetingID, leaseID: id) }
}

/// Admits whole-meeting operations across awaits. A waiting mutation blocks
/// new readers, so an export stream cannot starve deletion indefinitely.
public actor MeetingMutationCoordinator {
    private struct State {
        var active: [UUID: MeetingOperationAccess] = [:]
        var waitingWriters: [UUID] = []
    }
    private var states: [String: State] = [:]

    public init() {}

    public func acquire(meetingID: String, access: MeetingOperationAccess) async throws -> MeetingOperationLease {
        guard AppPaths.isSafeIdentifier(meetingID) else { throw EchoCoreError.invalidIdentifier(meetingID) }
        let id = UUID()
        if access == .exclusive { states[meetingID, default: State()].waitingWriters.append(id) }
        var admitted = false
        defer {
            if !admitted {
                states[meetingID]?.waitingWriters.removeAll { $0 == id }
                removeEmptyState(meetingID)
            }
        }
        while true {
            try Task.checkCancellation()
            let state = states[meetingID] ?? State()
            let canEnter: Bool
            switch access {
            case .read:
                canEnter = state.waitingWriters.isEmpty && !state.active.values.contains { $0 == .exclusive }
            case .exclusive:
                canEnter = state.active.isEmpty && state.waitingWriters.first == id
            }
            if canEnter {
                if access == .exclusive { states[meetingID]?.waitingWriters.removeAll { $0 == id } }
                states[meetingID, default: State()].active[id] = access
                admitted = true
                return MeetingOperationLease(coordinator: self, meetingID: meetingID, id: id)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    public func withLease<Value: Sendable>(meetingID: String, access: MeetingOperationAccess,
                                           operation: @Sendable () async throws -> Value) async throws -> Value {
        let lease = try await acquire(meetingID: meetingID, access: access)
        do {
            let value = try await operation()
            await lease.release()
            return value
        } catch {
            await lease.release()
            throw error
        }
    }

    fileprivate func release(meetingID: String, leaseID: UUID) {
        states[meetingID]?.active.removeValue(forKey: leaseID)
        removeEmptyState(meetingID)
    }

    private func removeEmptyState(_ meetingID: String) {
        if let state = states[meetingID], state.active.isEmpty && state.waitingWriters.isEmpty {
            states.removeValue(forKey: meetingID)
        }
    }

    func activeLeaseCount(meetingID: String) -> Int { states[meetingID]?.active.count ?? 0 }

    func waitForQueuedWriter(meetingID: String) async {
        while states[meetingID]?.waitingWriters.isEmpty != false {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }
}
