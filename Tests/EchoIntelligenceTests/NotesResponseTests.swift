import XCTest
@testable import EchoIntelligence

final class NotesResponseTests: XCTestCase {
    func testHarmonyUsesOnlyFinalChannel() throws {
        let response = "<|channel|>analysis<|message|>{\"secret\":true}<|channel|>final<|message|>{\"summary\":[]}<|return|>"
        XCTAssertEqual(try NotesResponse.finalText(response, modelID: "gptoss"), "{\"summary\":[]}")
        XCTAssertThrowsError(try NotesResponse.finalText("<|channel|>analysis<|message|>{}", modelID: "gptoss"))
    }
    func testUnfinishedThinkingIsNotMeetingNotes() throws {
        XCTAssertThrowsError(try NotesResponse.finalText("<think>draft", modelID: "notes"))
        XCTAssertEqual(try NotesResponse.finalText("<think>internal</think>{}", modelID: "notes"), "{}")
    }
}
