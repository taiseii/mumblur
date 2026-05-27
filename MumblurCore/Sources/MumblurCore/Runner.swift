import Foundation
import os

public final class Runner: @unchecked Sendable {
    public enum State: String, Sendable {
        case idle
        case recording
        case stopping
        case transcribing
    }

    public init(
        recorder: AudioRecording,
        transcriber: Transcribing,
        paster: Pasting,
        minHoldMs: Int = 200,
        clock: @escaping @Sendable () -> Date = { Date() },
        onStateChange: @escaping @Sendable (State) -> Void = { _ in }
    ) {
        self.recorder = recorder
        self.transcriber = transcriber
        self.paster = paster
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

        let task: Task<Void, Never> = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.doWork(samples: samples)
        }

        // If doWork already finished and reset state to .idle, do NOT overwrite
        // it — cancel the task as a no-op and leave state alone. Otherwise store
        // the handle so shutdown() can cancel it.
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
    private let transcriber: Transcribing
    private let paster: Pasting
    private let minHoldMs: Int
    private let clock: @Sendable () -> Date
    private let onStateChange: @Sendable (State) -> Void
    private let lock: OSAllocatedUnfairLock<MutableState>

    private func doWork(samples: [Float]) async {
        defer {
            lock.withLock { s in
                s.state = .idle
                s.worker = nil
            }
            onStateChange(.idle)
        }
        do {
            let text = try await transcriber.transcribe(samples)
            guard !Task.isCancelled,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return }
            await paster.paste(text)
        } catch is CancellationError {
            Logger.runner.debug("worker cancelled")
        } catch {
            Logger.transcribe.error("transcribe failed: \(error.localizedDescription)")
        }
    }
}
