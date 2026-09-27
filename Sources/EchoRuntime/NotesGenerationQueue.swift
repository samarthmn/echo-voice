import Foundation
import EchoCore

/// A retry without a saved draft resumes its durable job. Once any draft has
/// been saved, an explicit regeneration gets a new version, even for identical
/// evidence. This preserves partial drafts and human edits across retries.
struct NotesGenerationQueue {
    let store: MeetingStore

    func enqueue(meetingID: String, evidenceVersion: String) throws -> ProcessingJob {
        let windowID = ProcessingIdentity.id(meetingID, "notes", evidenceVersion)
        let jobs = try store.jobs(meetingID: meetingID).filter { $0.kind == .notes }
        let savedIDs = Set(try store.notes(meetingID: meetingID).map(\.id))
        let matching = jobs.compactMap { job -> (ProcessingJob, ProcessingWindow)? in
            guard let window = try? JSONDecoder().decode(ProcessingWindow.self, from: Data(job.payload.utf8)), window.windowID == windowID else { return nil }
            return (job, window)
        }.sorted { ($0.1.sequence ?? 0) > ($1.1.sequence ?? 0) }
        let next: ProcessingJob
        if let (job, _) = matching.first, job.status != .completed, job.status != .cancelled, !savedIDs.contains(job.id) {
            next = job
        } else {
            let sequence = (matching.map { $0.1.sequence ?? 0 }.max() ?? -1) + 1
            let window = ProcessingWindow(track: .remote, epochID: "notes", start: 0, duration: 0, windowID: windowID, provisional: false, relativePath: "", sequence: sequence)
            next = ProcessingJob(id: ProcessingIdentity.jobID(window, kind: .notes), meetingID: meetingID, kind: .notes, status: .pending, payload: String(decoding: try JSONEncoder().encode(window), as: UTF8.self), attempts: 0, error: nil, createdAt: Date())
            try store.enqueue(next)
        }
        for var old in jobs where old.id != next.id && old.status != .completed && old.status != .cancelled {
            old.status = .cancelled
            old.error = "Superseded by a new notes generation; any saved draft is retained"
            try store.updateJob(old)
        }
        return next
    }

    func save(_ draft: MeetingNotes, job: ProcessingJob, hasIncompleteEvidence: Bool) throws {
        var notes = draft
        notes.id = job.id
        notes.isPartial = draft.isPartial || hasIncompleteEvidence
        try store.saveNotes(notes)
        // Persist successful sections before surfacing the failure. The durable
        // scheduler marks this job retryable without overwriting its draft.
        if draft.isPartial { throw MeetingProcessingError.partialNotes }
    }
}
