import XCTest
@testable import EchoCore

final class LibraryMutationPolicyTests: XCTestCase {
    func testModelInstallAndLibraryImportWaitUntilTheLibraryIsReady() {
        XCTAssertFalse(LibraryMutationPolicy.allowsModelChanges(phase: .opening, setupBusy: false, recording: false, processing: false, changingRecording: false, importingLibrary: false, libraryImportPending: false))
        XCTAssertFalse(LibraryMutationPolicy.allowsLibraryImport(phase: .opening, setupBusy: false, recording: false, processing: false, changingRecording: false, importingLibrary: false, libraryImportPending: false, meetingCount: 0))
        XCTAssertFalse(LibraryMutationPolicy.allowsModelChanges(phase: .unavailable, setupBusy: false, recording: false, processing: false, changingRecording: false, importingLibrary: false, libraryImportPending: false))
        XCTAssertTrue(LibraryMutationPolicy.allowsModelChanges(phase: .ready, setupBusy: false, recording: false, processing: false, changingRecording: false, importingLibrary: false, libraryImportPending: false))
        XCTAssertTrue(LibraryMutationPolicy.allowsLibraryImport(phase: .ready, setupBusy: false, recording: false, processing: false, changingRecording: false, importingLibrary: false, libraryImportPending: false, meetingCount: 0))
        XCTAssertFalse(LibraryMutationPolicy.allowsLibraryImport(phase: .ready, setupBusy: false, recording: false, processing: false, changingRecording: false, importingLibrary: false, libraryImportPending: false, meetingCount: 1))
        XCTAssertFalse(LibraryMutationPolicy.allowsModelChanges(phase: .ready, setupBusy: false, recording: false, processing: false, changingRecording: false, importingLibrary: true, libraryImportPending: false))
        XCTAssertFalse(LibraryMutationPolicy.allowsModelChanges(phase: .ready, setupBusy: true, recording: false, processing: false, changingRecording: false, importingLibrary: false, libraryImportPending: false))
    }
}
