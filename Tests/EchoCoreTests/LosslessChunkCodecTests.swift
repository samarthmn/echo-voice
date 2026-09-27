import Foundation
import XCTest
@testable import EchoCore

final class LosslessChunkCodecTests: XCTestCase {
    func testExactRoundTripsForFloatPatternsAndNoise() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ECHO_TEST_ROOT"] ?? FileManager.default.currentDirectoryPath + "/tmp/tests")
            .appendingPathComponent("codec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let patterns: [UInt32] = [0, 0x80000000, 0x7fc00000, 0x7f800000, 0xff800000,
                                  0x3f800000, 0xbf800000, 0x00000001]
        let floats = Data((0..<200_000).flatMap { index -> [UInt8] in
            withUnsafeBytes(of: patterns[index % patterns.count].littleEndian, Array.init)
        })
        var state: UInt64 = 0x123456789abcdef0
        let noise = Data((0..<250_000).map { _ -> UInt8 in
            state = state &* 6364136223846793005 &+ 1
            return UInt8(truncatingIfNeeded: state >> 32)
        })
        for (name, content) in [("floats", floats), ("noise", noise), ("silence", Data(repeating: 0, count: 1_000_000))] {
            let source = root.appendingPathComponent(name + ".caf")
            let compressed = root.appendingPathComponent(name + ".lzfse")
            let restored = root.appendingPathComponent(name + "-restored.caf")
            try content.write(to: source)
            let encoded = try LosslessChunkCodec.compress(source, to: compressed)
            XCTAssertEqual(encoded.bytes, Int64(try Data(contentsOf: compressed).count))
            let decoded = try LosslessChunkCodec.decompress(compressed, to: restored, maximumBytes: Int64(content.count))
            XCTAssertEqual(decoded.bytes, Int64(content.count))
            XCTAssertEqual(try Data(contentsOf: restored), content)
        }
    }

    func testTruncatedStreamIsRejected() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ECHO_TEST_ROOT"] ?? FileManager.default.currentDirectoryPath + "/tmp/tests")
            .appendingPathComponent("codec-truncated-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("original")
        let compressed = root.appendingPathComponent("compressed")
        let restored = root.appendingPathComponent("restored")
        try Data(repeating: 3, count: 100_000).write(to: source)
        _ = try LosslessChunkCodec.compress(source, to: compressed)
        var data = try Data(contentsOf: compressed)
        data.removeLast(min(8, data.count))
        try data.write(to: compressed)
        XCTAssertThrowsError(try LosslessChunkCodec.decompress(compressed, to: restored, maximumBytes: 100_000))
        XCTAssertFalse(FileManager.default.fileExists(atPath: restored.path))
    }
}
