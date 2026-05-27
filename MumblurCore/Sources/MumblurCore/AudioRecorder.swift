import Foundation
import AVFoundation
import os

public protocol AudioRecording: AnyObject, Sendable {
    func start() throws
    func stop() -> [Float]
    func abortIfActive()
}

public final class AudioRecorder: AudioRecording, @unchecked Sendable {
    public static let sampleRate: Double = 16_000

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var chunks: [[Float]] = []
    private var converter: AVAudioConverter?
    private var active: Bool = false

    public init() throws {
        // Engine is lazily configured on start(); init only verifies we can ask
        // the input node for a format (which can throw on devices with no mic).
        _ = engine.inputNode.outputFormat(forBus: 0)
    }

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        if active {
            throw NSError(
                domain: "MumblurCore.AudioRecorder",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "already recording"]
            )
        }
        chunks = []

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(
                domain: "MumblurCore.AudioRecorder",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "cannot build target format"]
            )
        }

        // If the input is already 16 kHz mono float32, the converter is a no-op
        // identity. Otherwise it downsamples / mixes channels.
        if inputFormat.sampleRate != targetFormat.sampleRate
            || inputFormat.channelCount != targetFormat.channelCount {
            converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        } else {
            converter = nil
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.onAudio(buffer: buffer, targetFormat: targetFormat)
        }

        engine.prepare()
        try engine.start()
        active = true
        Logger.audio.debug("recording started")
    }

    public func stop() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        guard active else { return [] }
        active = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let out = chunks.flatMap { $0 }
        chunks = []
        Logger.audio.debug("recording stopped: \(out.count) samples")
        return out
    }

    public func abortIfActive() {
        lock.lock()
        defer { lock.unlock() }
        guard active else { return }
        active = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        chunks = []
    }

    private func onAudio(buffer: AVAudioPCMBuffer, targetFormat: AVAudioFormat) {
        let outBuffer: AVAudioPCMBuffer
        if let converter {
            let frameCapacity = AVAudioFrameCount(
                Double(buffer.frameLength) * targetFormat.sampleRate
                    / buffer.format.sampleRate
                + 1024
            )
            guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity)
            else { return }
            var err: NSError?
            let status = converter.convert(to: out, error: &err) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            if status == .error || err != nil { return }
            outBuffer = out
        } else {
            outBuffer = buffer
        }
        guard let floatChannelData = outBuffer.floatChannelData else { return }
        let frames = Int(outBuffer.frameLength)
        let monoPtr = floatChannelData[0]
        let samples = Array(UnsafeBufferPointer(start: monoPtr, count: frames))
        lock.lock()
        if active { chunks.append(samples) }
        lock.unlock()
    }
}
