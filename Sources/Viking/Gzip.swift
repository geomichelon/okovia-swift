import Foundation
import zlib

/// Minimal gzip (RFC 1952) encoder over the system zlib.
/// windowBits 15+16 asks zlib to emit the gzip container directly.
enum Gzip {
    static func compress(_ data: Data) throws -> Data {
        guard !data.isEmpty else { return data }

        var stream = z_stream()
        var status = deflateInit2_(
            &stream,
            Z_DEFAULT_COMPRESSION,
            Z_DEFLATED,
            15 + 16,
            8,
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard status == Z_OK else { throw GzipError.initFailed(status) }
        defer { deflateEnd(&stream) }

        var output = Data(capacity: data.count / 2 + 64)
        var input = data

        try input.withUnsafeMutableBytes { (inputPointer: UnsafeMutableRawBufferPointer) in
            stream.next_in = inputPointer.bindMemory(to: UInt8.self).baseAddress
            stream.avail_in = UInt32(data.count)

            let chunkSize = 16_384
            var chunk = [UInt8](repeating: 0, count: chunkSize)
            repeat {
                try chunk.withUnsafeMutableBufferPointer { chunkPointer in
                    stream.next_out = chunkPointer.baseAddress
                    stream.avail_out = UInt32(chunkSize)
                    status = deflate(&stream, Z_FINISH)
                    guard status == Z_OK || status == Z_STREAM_END || status == Z_BUF_ERROR else {
                        throw GzipError.deflateFailed(status)
                    }
                    output.append(contentsOf: chunkPointer.prefix(chunkSize - Int(stream.avail_out)))
                }
            } while status != Z_STREAM_END
        }

        return output
    }

    /// Decompression is used only by tests to prove round-trip integrity.
    static func decompress(_ data: Data) throws -> Data {
        guard !data.isEmpty else { return data }

        var stream = z_stream()
        var status = inflateInit2_(
            &stream,
            15 + 32,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard status == Z_OK else { throw GzipError.initFailed(status) }
        defer { inflateEnd(&stream) }

        var output = Data(capacity: data.count * 4)
        var input = data

        try input.withUnsafeMutableBytes { (inputPointer: UnsafeMutableRawBufferPointer) in
            stream.next_in = inputPointer.bindMemory(to: UInt8.self).baseAddress
            stream.avail_in = UInt32(data.count)

            let chunkSize = 16_384
            var chunk = [UInt8](repeating: 0, count: chunkSize)
            repeat {
                try chunk.withUnsafeMutableBufferPointer { chunkPointer in
                    stream.next_out = chunkPointer.baseAddress
                    stream.avail_out = UInt32(chunkSize)
                    status = inflate(&stream, Z_NO_FLUSH)
                    guard status == Z_OK || status == Z_STREAM_END || status == Z_BUF_ERROR else {
                        throw GzipError.inflateFailed(status)
                    }
                    output.append(contentsOf: chunkPointer.prefix(chunkSize - Int(stream.avail_out)))
                }
            } while status != Z_STREAM_END && stream.avail_in > 0

            guard status == Z_STREAM_END else { throw GzipError.inflateFailed(status) }
        }

        return output
    }
}

enum GzipError: Error {
    case initFailed(Int32)
    case deflateFailed(Int32)
    case inflateFailed(Int32)
}
