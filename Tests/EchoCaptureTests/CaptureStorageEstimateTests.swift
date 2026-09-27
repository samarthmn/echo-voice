import XCTest
import EchoCore
@testable import EchoCapture

final class CaptureStorageEstimateTests: XCTestCase {
    func testRawBudgetUsesTestedRateAndAllMicrophoneChannels() throws {
        let estimate = try CaptureStorageEstimate.calculate(formats: [.init(track: .remote, sampleRate: 48000, channels: 2), .init(track: .microphone, sampleRate: 96000, channels: 8)], echoCancellation: true)
        XCTAssertEqual(estimate.rawBytes, Int64((48000 * 2 + 96000 * 8) * 4) * 28800)
        XCTAssertGreaterThan(estimate.requiredBytes, estimate.rawBytes + 4_000_000_000)
    }
    func testSpeakerphoneIncludesNearFarCleanFullRemoteAndFailureInputs() throws {
        let formats: [CaptureAudioFormat] = [.init(track: .remote, sampleRate: 48000, channels: 2), .init(track: .microphone, sampleRate: 48000, channels: 1)]
        let speakers = try CaptureStorageEstimate.calculate(formats: formats, echoCancellation: true)
        let headphones = try CaptureStorageEstimate.calculate(formats: formats, echoCancellation: false)
        let derivedMinimum = Int64(28800 * 16000 * 2 * 4)
        XCTAssertGreaterThan(speakers.processingBytes, derivedMinimum)
        XCTAssertGreaterThanOrEqual(speakers.processingBytes - headphones.processingBytes, Int64(28800 * 16000 * 2 * 3))
        XCTAssertEqual(speakers.reserveBytes, 4_000_000_000)
    }
    func testSingleSourceDoesNotBudgetUnusedFullRemoteOrAECTracks() throws {
        let mic = try CaptureStorageEstimate.calculate(formats: [.init(track: .microphone, sampleRate: 48000, channels: 1)], echoCancellation: false)
        let remote = try CaptureStorageEstimate.calculate(formats: [.init(track: .remote, sampleRate: 48000, channels: 1)], echoCancellation: false)
        XCTAssertEqual(mic.rawBytes, remote.rawBytes)
        XCTAssertEqual(remote.processingBytes - mic.processingBytes, Int64(28800 * 16000 * 2))
    }
    func testRejectsInvalidAndOverflowingFormatsAndInconsistentAEC() {
        for rate in [0.0, -1.0, Double.nan, Double.infinity, Double.greatestFiniteMagnitude] {
            XCTAssertThrowsError(try CaptureStorageEstimate.calculate(formats: [.init(track: .microphone, sampleRate: rate, channels: 1)], echoCancellation: false))
        }
        XCTAssertThrowsError(try CaptureStorageEstimate.calculate(formats: [.init(track: .microphone, sampleRate: 48000, channels: 0)], echoCancellation: false))
        XCTAssertThrowsError(try CaptureStorageEstimate.calculate(formats: [.init(track: .microphone, sampleRate: 48000, channels: 1)], echoCancellation: true))
    }
}

final class CaptureFormatValidationTests: XCTestCase {
    private let mic = CaptureAudioFormat(track: .microphone, sampleRate: 48000, channels: 1)
    private let remote = CaptureAudioFormat(track: .remote, sampleRate: 48000, channels: 2)
    func testSameTestedFormatsAreAcceptedRegardlessOfEnumerationOrder() throws {
        try CaptureFormatValidation.verify(actual: [remote, mic], expected: [mic, remote])
    }
    func testRateAndChannelChangesRequireFreshInputTest() {
        XCTAssertThrowsError(try CaptureFormatValidation.verify(actual: [.init(track: .microphone, sampleRate: 96000, channels: 1), remote], expected: [mic, remote]))
        XCTAssertThrowsError(try CaptureFormatValidation.verify(actual: [.init(track: .microphone, sampleRate: 48000, channels: 8), remote], expected: [mic, remote]))
    }
    func testChangedSourceSetAndDuplicateProfilesAreRejected() {
        XCTAssertThrowsError(try CaptureFormatValidation.verify(actual: [mic], expected: [mic, remote]))
        XCTAssertThrowsError(try CaptureFormatValidation.verify(actual: [mic, mic], expected: [mic, mic]))
    }
    func testExplicitInputTestCanDiscoverFormatsWithoutAnExpectation() throws {
        try CaptureFormatValidation.verify(actual: [mic, remote], expected: nil)
    }
}
