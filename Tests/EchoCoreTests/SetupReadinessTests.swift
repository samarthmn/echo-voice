import XCTest
@testable import EchoCore

final class SetupReadinessTests: XCTestCase {
    private func inputs(_ change: (inout SetupReadiness.Inputs) -> Void = { _ in }) -> SetupReadiness.Inputs {
        var value = SetupReadiness.Inputs()
        value.libraryReady = true; value.runtimeChecked = true; value.runtimeAvailable = true
        value.speechModelID = "parakeet"; value.speechModelName = "Parakeet"; value.speechReady = true
        value.microphone = .granted
        change(&value)
        return value
    }

    func testFreshInstallRequiresSetup() {
        let readiness = SetupReadiness(inputs { $0.speechReady = false; $0.microphone = .notDetermined })
        XCTAssertEqual(readiness.overall, .setupRequired)
        XCTAssertFalse(readiness.requiredComplete)
        XCTAssertEqual(readiness.item(.speech)?.state, .actionNeeded)
    }

    func testReadyWhenRuntimeSpeechAndMicrophoneAreAvailable() {
        let readiness = SetupReadiness(inputs())
        XCTAssertEqual(readiness.overall, .ready)
        XCTAssertTrue(readiness.requiredComplete)
        XCTAssertEqual(readiness.item(.notes)?.state, .off)
        XCTAssertEqual(readiness.item(.meetingAudio)?.state, .informational)
    }

    func testActiveDownloadTakesPriorityAndMarksItsItem() {
        let readiness = SetupReadiness(inputs {
            $0.speechReady = false
            $0.download = .init(modelID: "parakeet", name: "Parakeet", fraction: 0.4)
        })
        XCTAssertEqual(readiness.overall, .downloading(0.4))
        XCTAssertEqual(readiness.item(.speech)?.state, .inProgress(0.4))
    }

    func testOptionalDownloadMatchesByModelID() {
        let readiness = SetupReadiness(inputs {
            $0.notes = .needsDownload(id: "notes", name: "Qwen3 4B")
            $0.download = .init(modelID: "notes", name: "Qwen3 4B", fraction: nil)
        })
        XCTAssertEqual(readiness.item(.notes)?.state, .inProgress(nil))
        XCTAssertEqual(readiness.item(.speech)?.state, .ready)
    }

    func testMicrophonePermissionIsSurfacedAfterRequiredSetup() {
        XCTAssertEqual(SetupReadiness(inputs { $0.microphone = .denied }).overall, .permissionNeeded)
        XCTAssertEqual(SetupReadiness(inputs { $0.microphone = .notDetermined }).overall, .permissionNeeded)
        XCTAssertEqual(SetupReadiness(inputs { $0.microphone = .denied }).item(.microphone)?.state, .problem)
    }

    func testBundledRuntimeFailureIsAProblemNotAnInstallStep() {
        let bundled = SetupReadiness(inputs { $0.runtimeAvailable = false })
        XCTAssertEqual(bundled.item(.runtime)?.state, .problem)
        XCTAssertEqual(bundled.overall, .setupRequired)
        let development = SetupReadiness(inputs { $0.runtimeAvailable = false; $0.runtimeBundled = false })
        XCTAssertEqual(development.item(.runtime)?.state, .actionNeeded)
    }

    func testLibraryProblemAndStartupStates() {
        XCTAssertEqual(SetupReadiness(inputs { $0.libraryProblem = "Broken" }).overall, .attention("Broken"))
        XCTAssertEqual(SetupReadiness(inputs { $0.runtimeChecked = false }).overall, .checking)
        XCTAssertEqual(SetupReadiness(inputs { $0.libraryReady = false }).overall, .checking)
    }

    func testDownloadTallySumsDependencyAssets() {
        var tally = DownloadTally(assetSizes: ["diarization": 100, "segmentation": 300, "embedding": 600])
        XCTAssertEqual(tally.totalBytes, 1000)
        tally.markComplete(asset: "diarization")
        tally.record(asset: "segmentation", completedBytes: 150)
        XCTAssertEqual(tally.fraction, 0.25, accuracy: 0.0001)
        tally.record(asset: "segmentation", completedBytes: 50)
        XCTAssertEqual(tally.completedBytes, 250, "Progress never moves backwards within an asset")
        tally.record(asset: "embedding", completedBytes: 10_000)
        XCTAssertEqual(tally.completedBytes, 850, "Reported bytes are capped at the asset size")
        tally.record(asset: "unknown", completedBytes: 10)
        XCTAssertEqual(tally.completedBytes, 850)
    }

    func testCatalogExposesDependencyAssets() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let catalog = try ModelCatalog(url: root.appendingPathComponent("service/models.json"))
        XCTAssertEqual(Set(catalog.assets(includingDependenciesOf: "diarization")), ["diarization", "segmentation", "embedding"])
        let tally = DownloadTally(catalog: catalog, modelID: "diarization")
        XCTAssertEqual(tally.totalBytes, catalog.downloadBytes(includingDependenciesOf: "diarization"))
    }
}
