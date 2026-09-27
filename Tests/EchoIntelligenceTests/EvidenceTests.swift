import XCTest
@testable import EchoIntelligence

final class EvidenceTests: XCTestCase {
    func testRejectsMissingEvidenceAndUnknownReferences() {
        XCTAssertFalse(EvidenceValidator.isSupported([], allowed: ["s1"]))
        XCTAssertFalse(EvidenceValidator.isSupported(["invented"], allowed: ["s1"]))
        XCTAssertTrue(EvidenceValidator.isSupported(["s1"], allowed: ["s1"]))
    }

    func testExtractsJSONWithoutTrustingModelCommentary() throws {
        let result = try EvidenceValidator.jsonObject(from: "Here is the draft:\n```json\n{\"summary\": []}\n```\n")
        XCTAssertEqual(String(data: result, encoding: .utf8), "{\"summary\": []}")
        XCTAssertThrowsError(try EvidenceValidator.jsonObject(from: "No supported facts."))
    }

    func testPartitionsLongEvidenceWithoutLosingItems() {
        let batches = EvidenceValidator.batches(["abcd", "efgh", "ij"], characterBudget: 8)
        XCTAssertEqual(batches.flatMap { $0 }, ["abcd", "efgh", "ij"])
        XCTAssertTrue(batches.allSatisfy { $0.joined().count <= 8 })
    }

    func testVisibleProposalCannotBecomeSpokenCommitment() {
        XCTAssertFalse(EvidenceValidator.supportsCommitment(["slide"], allowed: ["slide", "speech"], transcriptIDs: ["speech"]))
        XCTAssertTrue(EvidenceValidator.supportsCommitment(["speech", "slide"], allowed: ["slide", "speech"], transcriptIDs: ["speech"]))
        XCTAssertFalse(EvidenceValidator.supportsCommitment(["speech"], allowed: ["slide"], transcriptIDs: ["speech"]))
    }

    func testOversizedHumanEditIsBoundedWithoutLosingText() {
        let input = String(repeating: "A meaningful correction. ", count: 2000)
        let parts = EvidenceValidator.boundedParts(input)
        XCTAssertEqual(parts.joined(), input)
        XCTAssertTrue(parts.allSatisfy { $0.count <= 8000 })
    }
}
