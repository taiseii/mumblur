import Foundation
import os

/// Persistence seam consumed by the dictation pipeline. The concrete implementation
/// is `RetentionAwarePersister` (Task 21.5); the protocol takes the samples buffer
/// so the persister can write audio when retention is enabled. Persist failures are
/// handled inside the persister and never propagate (paste already happened).
public protocol DictationPersisting: Sendable {
    func persist(samples: [Float],
                 snapshot: ServingSnapshot,
                 startedAt: Date,
                 durationMs: Int,
                 rawText: String,
                 finalText: String) async
}

public final class Runner: @unchecked Sendable {
    public enum State: String, Sendable {
        case idle
        case recording
        case stopping
        case transcribing
    }

    public init(
        recorder: AudioRecording,
        transcriber: Transcriber,
        paster: Pasting,
        persister: any DictationPersisting,
        minHoldMs: Int = 200,
        clock: @escaping @Sendable () -> Date = { Date() },
        onStateChange: @escaping @Sendable (State) -> Void = { _ in }
    ) {
        self.recorder = recorder
        self.transcriber = transcriber
        self.paster = paster
        self.persister = persister
        self.minHoldMs = minHoldMs
        self.clock = clock
        self.onStateChange = onStateChange
        self.lock = OSAllocatedUnfairLock(initialState: MutableState())
    }

    public var state: State { lock.withLock { $0.state } }

    public func onPress() {
        let shouldStart: Bool = lock.withLock { s in
            guard s.state == .idle else {
                let stateVal = s.state.rawValue
                Logger.runner.info("press ignored (state=\(stateVal))")
                return false
            }
            s.state = .recording
            s.pressTime = clock()
            return true
        }
        guard shouldStart else { return }
        onStateChange(.recording)
        do {
            try recorder.start()
        } catch {
            Logger.runner.error("recorder.start failed: \(error.localizedDescription)")
            lock.withLock { $0.state = .idle }
            onStateChange(.idle)
        }
    }

    public func onRelease() {
        let snap: (pressTime: Date, ok: Bool) = lock.withLock { s in
            guard s.state == .recording else { return (Date.distantPast, false) }
            s.state = .stopping
            return (s.pressTime, true)
        }
        guard snap.ok else { return }
        onStateChange(.stopping)

        let samples = recorder.stop()
        let heldMs = Int(clock().timeIntervalSince(snap.pressTime) * 1000)
        if heldMs < minHoldMs {
            lock.withLock { $0.state = .idle }
            onStateChange(.idle)
            return
        }

        lock.withLock { $0.state = .transcribing }
        onStateChange(.transcribing)

        let startedAt = snap.pressTime
        let task: Task<Void, Never> = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.doWork(samples: samples, startedAt: startedAt, durationMs: heldMs)
        }

        let shouldCancel: Bool = lock.withLock { s in
            guard s.state == .transcribing else { return true }
            s.worker = task
            return false
        }
        if shouldCancel { task.cancel() }
    }

    public func shutdown() {
        let (priorWorker, _) = lock.withLock { s -> (Task<Void, Never>?, State) in
            let w = s.worker
            s.worker = nil
            let was = s.state
            s.state = .idle
            return (w, was)
        }
        priorWorker?.cancel()
        recorder.abortIfActive()
        onStateChange(.idle)
    }

    // MARK: - Private

    private struct MutableState {
        var state: State = .idle
        var pressTime: Date = .distantPast
        var worker: Task<Void, Never>? = nil
    }

    private let recorder: AudioRecording
    private let transcriber: Transcriber
    private let paster: Pasting
    private let persister: any DictationPersisting
    private let postProcessor = TranscriptPostProcessor()
    private let minHoldMs: Int
    private let clock: @Sendable () -> Date
    private let onStateChange: @Sendable (State) -> Void
    private let lock: OSAllocatedUnfairLock<MutableState>

    private func doWork(samples: [Float], startedAt: Date, durationMs: Int) async {
        defer {
            lock.withLock { s in
                s.state = .idle
                s.worker = nil
            }
            onStateChange(.idle)
        }
        do {
            let output = try await transcriber.transcribe(samples)
            guard !Task.isCancelled else { return }
            let finalText = postProcessor.apply(output.rawText, rules: output.snapshot.rules)
            guard !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            await paster.paste(finalText)
            // Awaited on the worker (already off the UI). Persist failures are handled
            // inside the persister and never propagate — paste already happened.
            await persister.persist(
                samples: samples,
                snapshot: output.snapshot,
                startedAt: startedAt,
                durationMs: durationMs,
                rawText: output.rawText,
                finalText: finalText)
        } catch is CancellationError {
            Logger.runner.debug("worker cancelled")
        } catch {
            Logger.transcribe.error("transcribe failed: \(error.localizedDescription)")
        }
    }
}
