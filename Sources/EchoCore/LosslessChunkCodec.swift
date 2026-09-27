import Foundation
import Compression
import CryptoKit

public enum LosslessChunkCodec {
    public enum CodecError: LocalizedError {
        case corrupt, oversized
        public var errorDescription: String? {
            switch self {
            case .corrupt: "Compressed audio is incomplete or invalid. The original recording was not changed."
            case .oversized: "Compressed audio exceeds its declared decoded size."
            }
        }
    }

    public struct Result: Sendable {
        public let bytes: Int64
        public let sha256: String
    }

    public static func compress(_ input: URL, to output: URL, maximumBytes: Int64 = 64 * 1_024 * 1_024) throws -> Result {
        try transform(input, to: output, operation: COMPRESSION_STREAM_ENCODE, maximumBytes: maximumBytes)
    }

    public static func decompress(_ input: URL, to output: URL, maximumBytes: Int64) throws -> Result {
        try transform(input, to: output, operation: COMPRESSION_STREAM_DECODE, maximumBytes: maximumBytes)
    }

    private static func transform(_ input: URL, to output: URL, operation: compression_stream_operation,
                                  maximumBytes: Int64) throws -> Result {
        guard maximumBytes > 0 else { throw CodecError.oversized }
        let fileManager = FileManager.default
        guard fileManager.createFile(atPath: output.path, contents: nil) else { throw CodecError.corrupt }
        do {
            let reader = try FileHandle(forReadingFrom: input)
            let writer = try FileHandle(forWritingTo: output)
            defer { try? reader.close(); try? writer.close() }
            let placeholder = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
            defer { placeholder.deallocate() }
            var stream = compression_stream(dst_ptr: placeholder, dst_size: 0,
                                            src_ptr: UnsafePointer(placeholder), src_size: 0, state: nil)
            guard compression_stream_init(&stream, operation, COMPRESSION_LZFSE) == COMPRESSION_STATUS_OK else {
                throw CodecError.corrupt
            }
            defer { compression_stream_destroy(&stream) }
            let capacity = 64 * 1_024
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
            defer { buffer.deallocate() }
            var bytesWritten: Int64 = 0
            var digest = SHA256()
            while true {
                let chunk = try reader.read(upToCount: capacity) ?? Data()
                let endOfInput = chunk.isEmpty
                var completed = false
                try chunk.withUnsafeBytes { raw in
                    stream.src_ptr = raw.bindMemory(to: UInt8.self).baseAddress ?? UnsafePointer(placeholder)
                    stream.src_size = chunk.count
                    while true {
                        stream.dst_ptr = buffer
                        stream.dst_size = capacity
                        let status = compression_stream_process(&stream, endOfInput ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0)
                        guard status != COMPRESSION_STATUS_ERROR else { throw CodecError.corrupt }
                        let produced = capacity - stream.dst_size
                        if produced > 0 {
                            bytesWritten += Int64(produced)
                            guard bytesWritten <= maximumBytes else { throw CodecError.oversized }
                            let data = Data(bytes: buffer, count: produced)
                            digest.update(data: data)
                            try writer.write(contentsOf: data)
                        }
                        if status == COMPRESSION_STATUS_END { completed = true; break }
                        if stream.src_size == 0 && !endOfInput { break }
                        if endOfInput && produced == 0 { throw CodecError.corrupt }
                    }
                }
                if completed {
                    try writer.synchronize()
                    return Result(bytes: bytesWritten,
                                  sha256: digest.finalize().map { String(format: "%02x", $0) }.joined())
                }
                if endOfInput { throw CodecError.corrupt }
            }
        } catch {
            try? fileManager.removeItem(at: output)
            throw error
        }
    }
}
