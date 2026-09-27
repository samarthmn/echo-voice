import XCTest
@testable import EchoIntelligence

final class EvidenceAliasTests: XCTestCase {
    func testLongStableIDsRoundTripThroughShortExactReferences() {
        let ids = (0..<22).map { String(format: "%064x", $0) }
        let aliases = EvidenceAliases(ids: ids)
        XCTAssertEqual(aliases.reference(for: ids[0]), "E1")
        XCTAssertEqual(aliases.reference(for: ids[21]), "E22")
        XCTAssertEqual(aliases.resolve(["E22", "E1"], allowed: Set(ids)), [ids[21], ids[0]])
    }

    func testUnknownOrOutOfBatchReferenceRejectsEntireBullet() {
        let aliases = EvidenceAliases(ids: ["spoken", "visual", "other-batch"])
        XCTAssertNil(aliases.resolve(["E1", "E999"], allowed: ["spoken", "visual"]))
        XCTAssertNil(aliases.resolve(["E1", "E3"], allowed: ["spoken", "visual"]))
        XCTAssertNil(aliases.resolve(["spoken"], allowed: ["spoken"]))
        XCTAssertNil(aliases.resolve([], allowed: ["spoken"]))
    }

    func testRepeatedEvidenceKeepsOneAliasAndVisualReferencesStayDistinct() {
        let aliases = EvidenceAliases(ids: ["spoken", "spoken", "visual"])
        XCTAssertEqual(aliases.reference(for: "visual"), "E2")
        let visual = aliases.resolve(["E2"], allowed: ["spoken", "visual"])!
        XCTAssertFalse(EvidenceValidator.supportsCommitment(visual, allowed: ["spoken", "visual"], transcriptIDs: ["spoken"]))
        XCTAssertEqual(aliases.id(for: "E1"), "spoken")
        XCTAssertNil(aliases.id(for: "e1"))
    }
}
