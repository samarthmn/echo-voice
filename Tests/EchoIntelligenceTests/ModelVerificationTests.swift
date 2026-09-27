import Foundation
import XCTest
import CryptoKit
@testable import EchoIntelligence

final class ModelVerificationTests: XCTestCase {
    func testPinnedFilesAndGitBlobDigestAreAccepted() throws {
        let fixture = try VerificationFixture(); defer { fixture.remove() }
        let verifier = ModelVerifier(manifestURL: fixture.manifestURL)
        XCTAssertTrue(verifier.verify(name: "notes", modelsURL: fixture.modelsURL, expectedRevision: fixture.revision))
        XCTAssertTrue(verifier.verify(name: "notes", modelsURL: fixture.modelsURL))
    }

    func testMissingAndTruncatedWeightsAreRejected() throws {
        let fixture = try VerificationFixture(); defer { fixture.remove() }
        let verifier = ModelVerifier(manifestURL: fixture.manifestURL)
        try Data([1]).write(to: fixture.weightsURL)
        XCTAssertFalse(verifier.verify(name: "notes", modelsURL: fixture.modelsURL))
        try FileManager.default.removeItem(at: fixture.weightsURL)
        XCTAssertFalse(verifier.verify(name: "notes", modelsURL: fixture.modelsURL))
    }

    func testSameSizeCorruptionInvalidatesCachedVerificationEvenWithRestoredModificationDate() throws {
        let fixture = try VerificationFixture(); defer { fixture.remove() }
        let verifier = ModelVerifier(manifestURL: fixture.manifestURL)
        XCTAssertTrue(verifier.verify(name: "notes", modelsURL: fixture.modelsURL))
        let originalDate = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: fixture.weightsURL.path)[.modificationDate] as? Date)
        let handle = try FileHandle(forWritingTo: fixture.weightsURL)
        try handle.write(contentsOf: Data(repeating: 9, count: fixture.weights.count)); try handle.close()
        try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: fixture.weightsURL.path)
        XCTAssertFalse(verifier.verify(name: "notes", modelsURL: fixture.modelsURL))
    }

    func testReceiptAndCallerRevisionMustMatchManifest() throws {
        let fixture = try VerificationFixture(); defer { fixture.remove() }
        let verifier = ModelVerifier(manifestURL: fixture.manifestURL)
        XCTAssertFalse(verifier.verify(name: "notes", modelsURL: fixture.modelsURL, expectedRevision: String(repeating: "b", count: 40)))
        try fixture.writeReceipt(revision: String(repeating: "b", count: 40))
        XCTAssertFalse(verifier.verify(name: "notes", modelsURL: fixture.modelsURL))
        try Data("{}".utf8).write(to: fixture.directory.appendingPathComponent(".verified.json"))
        XCTAssertFalse(verifier.verify(name: "notes", modelsURL: fixture.modelsURL))
    }

    func testReceiptCannotAuthorizeChangedFiles() throws {
        let fixture = try VerificationFixture(); defer { fixture.remove() }
        let changed = Data(repeating: 9, count: fixture.weights.count)
        try changed.write(to: fixture.weightsURL)
        try fixture.writeReceipt(revision: fixture.revision, extra: ["files": [["path": "model.safetensors", "sha256": VerificationFixture.sha256(changed)]]])
        XCTAssertFalse(ModelVerifier(manifestURL: fixture.manifestURL).verify(name: "notes", modelsURL: fixture.modelsURL))
    }

    func testModelFileAndDirectorySymlinksAreRejected() throws {
        let fixture = try VerificationFixture(); defer { fixture.remove() }
        let verifier = ModelVerifier(manifestURL: fixture.manifestURL)
        let outside = fixture.root.appendingPathComponent("outside.safetensors")
        try fixture.weights.write(to: outside)
        try FileManager.default.removeItem(at: fixture.weightsURL)
        try FileManager.default.createSymbolicLink(at: fixture.weightsURL, withDestinationURL: outside)
        XCTAssertFalse(verifier.verify(name: "notes", modelsURL: fixture.modelsURL))
        try FileManager.default.removeItem(at: fixture.weightsURL)
        try fixture.weights.write(to: fixture.weightsURL)
        let relocated = fixture.root.appendingPathComponent("relocated")
        try FileManager.default.moveItem(at: fixture.directory, to: relocated)
        try FileManager.default.createSymbolicLink(at: fixture.directory, withDestinationURL: relocated)
        XCTAssertFalse(verifier.verify(name: "notes", modelsURL: fixture.modelsURL))
    }

    func testReceiptSymlinkAndGitBlobConfigCorruptionAreRejected() throws {
        let fixture = try VerificationFixture(); defer { fixture.remove() }
        let verifier = ModelVerifier(manifestURL: fixture.manifestURL)
        let receipt = fixture.directory.appendingPathComponent(".verified.json")
        let outside = fixture.root.appendingPathComponent("receipt.json")
        try FileManager.default.moveItem(at: receipt, to: outside)
        try FileManager.default.createSymbolicLink(at: receipt, withDestinationURL: outside)
        XCTAssertFalse(verifier.verify(name: "notes", modelsURL: fixture.modelsURL))
        try FileManager.default.removeItem(at: receipt)
        try fixture.writeReceipt(revision: fixture.revision)
        try Data("jello\n".utf8).write(to: fixture.directory.appendingPathComponent("config.json"))
        XCTAssertFalse(verifier.verify(name: "notes", modelsURL: fixture.modelsURL))
    }

    func testUnlistedNestedWeightsAreRejectedAfterCacheWasPopulated() throws {
        let fixture = try VerificationFixture(); defer { fixture.remove() }
        let verifier = ModelVerifier(manifestURL: fixture.manifestURL)
        XCTAssertTrue(verifier.verify(name: "notes", modelsURL: fixture.modelsURL))
        let extra = fixture.directory.appendingPathComponent("extra/override.safetensors")
        try FileManager.default.createDirectory(at: extra.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fixture.weights.write(to: extra)
        XCTAssertFalse(verifier.verify(name: "notes", modelsURL: fixture.modelsURL))
    }

    func testUnsafeManifestPathAndUnsupportedNameAreRejected() throws {
        let fixture = try VerificationFixture(); defer { fixture.remove() }
        XCTAssertFalse(ModelVerifier(manifestURL: fixture.manifestURL).verify(name: "../notes", modelsURL: fixture.modelsURL))
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.manifestURL)) as? [String: Any])
        var models = try XCTUnwrap(manifest["models"] as? [String: [String: Any]])
        var notes = try XCTUnwrap(models["notes"])
        var files = try XCTUnwrap(notes["files"] as? [[String: Any]])
        files[0]["path"] = "../config.json"; notes["files"] = files; models["notes"] = notes; manifest["models"] = models
        try JSONSerialization.data(withJSONObject: manifest).write(to: fixture.manifestURL)
        XCTAssertFalse(ModelVerifier(manifestURL: fixture.manifestURL).verify(name: "notes", modelsURL: fixture.modelsURL))
    }

    func testMalformedOrEmptyManifestFailsClosed() throws {
        let fixture = try VerificationFixture(); defer { fixture.remove() }
        try Data("{}".utf8).write(to: fixture.manifestURL)
        XCTAssertFalse(ModelVerifier(manifestURL: fixture.manifestURL).verify(name: "notes", modelsURL: fixture.modelsURL))
    }
}

private struct VerificationFixture {
    let root: URL
    let modelsURL: URL
    let manifestURL: URL
    let directory: URL
    let revision = String(repeating: "a", count: 40)
    let weights = Data([0, 1, 2, 3, 4, 5, 6, 7])
    var weightsURL: URL { directory.appendingPathComponent("model.safetensors") }

    init() throws {
        let base = ProcessInfo.processInfo.environment["ECHO_TEST_ROOT"] ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("tmp/tests").path
        root = URL(fileURLWithPath: base).appendingPathComponent("model-verification-\(UUID().uuidString)")
        modelsURL = root.appendingPathComponent("models")
        manifestURL = root.appendingPathComponent("manifest.json")
        directory = modelsURL.appendingPathComponent("notes").appendingPathComponent(revision)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let config = Data("hello\n".utf8), tokenizer = Data("tokenizer".utf8)
        try config.write(to: directory.appendingPathComponent("config.json"))
        try tokenizer.write(to: directory.appendingPathComponent("tokenizer.json"))
        try weights.write(to: weightsURL)
        let files: [[String: Any]] = [
            ["path": "config.json", "size": config.count, "sha256": NSNull(), "git_blob_sha1": "ce013625030ba8dba906f756967f9e9ca394464a"],
            ["path": "tokenizer.json", "size": tokenizer.count, "sha256": Self.sha256(tokenizer), "git_blob_sha1": NSNull()],
            ["path": "model.safetensors", "size": weights.count, "sha256": Self.sha256(weights), "git_blob_sha1": NSNull()],
        ]
        try JSONSerialization.data(withJSONObject: ["models": ["notes": ["revision": revision, "files": files]]]).write(to: manifestURL)
        try writeReceipt(revision: revision)
    }

    func writeReceipt(revision: String, extra: [String: Any] = [:]) throws {
        var object = extra; object["revision"] = revision
        try JSONSerialization.data(withJSONObject: object).write(to: directory.appendingPathComponent(".verified.json"))
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
