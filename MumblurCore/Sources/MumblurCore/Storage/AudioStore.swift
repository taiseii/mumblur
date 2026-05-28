// MumblurCore/Sources/MumblurCore/Storage/AudioStore.swift
import Foundation
import CryptoKit

public actor AudioStore {
    public struct WrittenAudio: Sendable {
        public let relPath: String
        public let absoluteURL: URL
        public let bytes: Int64
        public let sha256: String
    }

    public enum AudioStoreError: Error { case writeFailed }

    private let root: URL
    private let clipsDir: URL

    public init(root: URL) {
        self.root = root
        self.clipsDir = root.appendingPathComponent("clips", isDirectory: true)
        try? FileManager.default.createDirectory(at: clipsDir, withIntermediateDirectories: true)
    }

    /// Writes a 16-bit PCM mono WAV. UUID-named so the filename is known before any DB insert.
    /// Streams header + PCM in chunks to a `.part` file, hashing incrementally, fsyncs, then
    /// atomically moves to the final path. Never re-reads the file to hash it.
    public func write(samples: [Float], sampleRateHz: Int) throws -> WrittenAudio {
        let id = UUID().uuidString
        let relPath = "clips/\(id).wav"
        let url = root.appendingPathComponent(relPath)
        let tmpURL = url.appendingPathExtension("part")

        let pcm = samples.map { Int16(max(-1.0, min(1.0, $0)) * 32767) }
        let pcmData = pcm.withUnsafeBufferPointer { Data(buffer: $0) }
        let header = wavHeader(dataSize: UInt32(pcmData.count), sampleRateHz: sampleRateHz)
        let totalBytes = Int64(header.count + pcmData.count)

        guard FileManager.default.createFile(atPath: tmpURL.path, contents: nil) else {
            throw AudioStoreError.writeFailed
        }
        let handle = try FileHandle(forWritingTo: tmpURL)

        var hasher = SHA256()
        do {
            try handle.write(contentsOf: header)
            hasher.update(data: header)

            let chunkSize = 64 * 1024
            var offset = 0
            while offset < pcmData.count {
                let end = min(offset + chunkSize, pcmData.count)
                let chunk = pcmData.subdata(in: offset..<end)
                try handle.write(contentsOf: chunk)
                hasher.update(data: chunk)
                offset = end
            }
            try handle.synchronize()   // fsync
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: tmpURL)
            throw error
        }

        try FileManager.default.moveItem(at: tmpURL, to: url)

        let sha = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return WrittenAudio(relPath: relPath, absoluteURL: url, bytes: totalBytes, sha256: sha)
    }

    /// Removes WAVs in `clips/` not referenced by any transcript row.
    /// `referenced` is an async closure so the caller can pass its DB query.
    public func cleanupOrphans(referencedRelPaths referenced: @Sendable () async throws -> Set<String>) async throws {
        let ref = try await referenced()
        let items = (try? FileManager.default.contentsOfDirectory(
            at: clipsDir, includingPropertiesForKeys: nil)) ?? []
        for url in items where url.pathExtension == "wav" {
            let rel = "clips/\(url.lastPathComponent)"
            if !ref.contains(rel) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    public nonisolated func absoluteURL(forRelPath rel: String) -> URL {
        root.appendingPathComponent(rel)
    }

    private func wavHeader(dataSize: UInt32, sampleRateHz: Int) -> Data {
        // 16-bit PCM, mono — 44-byte canonical WAV header.
        let chunkSize = 36 + dataSize
        var out = Data()
        out.append("RIFF".data(using: .ascii)!)
        out.append(UInt32(chunkSize).littleEndianData)
        out.append("WAVE".data(using: .ascii)!)
        out.append("fmt ".data(using: .ascii)!)
        out.append(UInt32(16).littleEndianData)            // PCM subchunk size
        out.append(UInt16(1).littleEndianData)             // audioFormat = 1 (PCM)
        out.append(UInt16(1).littleEndianData)             // channels = 1
        out.append(UInt32(sampleRateHz).littleEndianData)
        out.append(UInt32(sampleRateHz * 2).littleEndianData) // byteRate
        out.append(UInt16(2).littleEndianData)             // blockAlign
        out.append(UInt16(16).littleEndianData)            // bitsPerSample
        out.append("data".data(using: .ascii)!)
        out.append(dataSize.littleEndianData)
        return out
    }
}

private extension FixedWidthInteger {
    var littleEndianData: Data {
        var v = self.littleEndian; return Data(bytes: &v, count: MemoryLayout<Self>.size)
    }
}
