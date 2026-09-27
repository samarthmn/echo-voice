import Foundation

public enum LibraryOpenPhase: String, Sendable, Equatable {
    case opening, ready, unavailable
}

public enum LibraryMutationPolicy {
    public static func allowsModelChanges(phase: LibraryOpenPhase, setupBusy: Bool, recording: Bool, processing: Bool, changingRecording: Bool, importingLibrary: Bool, libraryImportPending: Bool) -> Bool {
        phase == .ready && !setupBusy && !recording && !processing && !changingRecording && !importingLibrary && !libraryImportPending
    }

    public static func allowsLibraryImport(phase: LibraryOpenPhase, setupBusy: Bool, recording: Bool, processing: Bool, changingRecording: Bool, importingLibrary: Bool, libraryImportPending: Bool, meetingCount: Int) -> Bool {
        meetingCount == 0 && allowsModelChanges(phase: phase, setupBusy: setupBusy, recording: recording, processing: processing, changingRecording: changingRecording, importingLibrary: importingLibrary, libraryImportPending: libraryImportPending)
    }
}
