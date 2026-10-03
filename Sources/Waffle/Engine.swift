// The speech models every recording shares, all from FluidAudio and all on this Mac: Parakeet TDT 0.6B v3 "ultra" (speech to text, 25
// European languages, detected per sentence, never translated; Core ML on the Neural Engine, so the GPU and CPU stay free for the call),
// Silero (is someone speaking) and the speaker models. They load when a call starts (or its prompt shows) and go again 10 minutes after
// the last recording, so the Mac does not hold them all day. Every model call goes through one gate, one at a time, in order: FluidAudio's
// models must not predict at the same time (FluidAudio #661), and the passes of one speaker must come back in order.
import CoreML
import FluidAudio
import Foundation
import OSLog

let log = Logger(subsystem: "io.github.oufinx.waffle", category: "audio")

/// One at a time, in the order asked.
actor Gate {
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func leave() {
        if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
    }
}

final class Engine: @unchecked Sendable {
    static let shared = Engine()
    static let asrVersion = AsrModelVersion.ultra

    private let gate = Gate()
    private let lock = NSLock()
    /// The fields below, under the lock (from sync code only: an NSLock must not be held across an await).
    private func locked<T>(_ f: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return f() }
    private var asr: AsrManager?
    private var vad: VadManager?
    private var loading: Task<Void, Error>?
    private var users = 0  // recordings that use the models now
    private var unload: DispatchWorkItem?

    /// The speech model is on this Mac (the first-run setup downloads it).
    static var downloaded: Bool { AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: asrVersion), version: asrVersion) }

    /// Run `work` alone: no other model call runs meanwhile.
    func exclusive<T>(_ work: () async throws -> T) async rethrows -> T {
        await gate.enter()
        do { let r = try await work(); await gate.leave(); return r } catch { await gate.leave(); throw error }
    }

    // MARK: loading

    /// Start loading the models if they are not loaded, so they are ready when recording starts. Safe to call often.
    func prepare() {
        locked {
            unload?.cancel(); unload = nil
            if loading == nil, Self.downloaded { loading = Task.detached(priority: .userInitiated) { [self] in try await load() } }
            if users == 0 { scheduleUnload() }  // loaded for a call that may not get recorded: not for long
        }
    }

    /// Under the lock: drop the models in 10 minutes unless something uses them by then.
    private func scheduleUnload() {
        let w = DispatchWorkItem { [weak self] in self?.drop() }
        unload?.cancel(); unload = w
        DispatchQueue.global().asyncAfter(deadline: .now() + 600, execute: w)
    }

    /// A recording starts using the models: they stay until it ends.
    func retain() { locked { users += 1 }; prepare(); locked { unload?.cancel(); unload = nil } }

    /// A recording ended: the models go after a while unless another one starts.
    func release() {
        locked {
            users = max(0, users - 1)
            if users == 0 { scheduleUnload() }
        }
    }

    private func drop() {
        let l: Task<Void, Error>? = locked {
            guard users == 0, let l = loading else { return nil }
            loading = nil
            return l
        }
        guard let l else { return }
        Task.detached { [self] in
            _ = try? await l.value
            let a = locked { () -> AsrManager? in let a = asr; asr = nil; vad = nil; return a }
            await exclusive { await a?.cleanup() }
            log.info("speech models unloaded")
        }
    }

    private func load() async throws {
        let started = Date()
        let models = try await AsrModels.load(from: AsrModels.defaultCacheDirectory(for: Self.asrVersion), version: Self.asrVersion)
        let a = AsrManager(config: .default)
        try await a.loadModels(models)
        let v = try? await VadManager(config: VadConfig(defaultThreshold: 0.5))
        locked { asr = a; vad = v }
        // The first pass on the Neural Engine is slow; make it now rather than on the first words of the call.
        _ = try? await transcribe(quiet(16000))
        log.info("speech models ready in \(Date().timeIntervalSince(started), format: .fixed(precision: 1)) s")
    }

    /// The models, loading them first if needed. Throws when they are not downloaded or do not load.
    private func ready() async throws -> AsrManager {
        let (a, l): (AsrManager?, Task<Void, Error>?) = locked {
            if let a = asr { return (a, nil) }
            if loading == nil, Self.downloaded { loading = Task.detached(priority: .userInitiated) { [self] in try await load() } }
            return (nil, loading)
        }
        if let a { return a }
        guard let l else { throw NSError(domain: "Waffle", code: 1, userInfo: [NSLocalizedDescriptionKey: "The speech model is not downloaded yet: finish the setup first"]) }
        do { try await l.value } catch {
            locked { loading = nil }
            throw error
        }
        guard let loaded = locked({ asr }) else { throw NSError(domain: "Waffle", code: 2, userInfo: [NSLocalizedDescriptionKey: "The speech model did not load"]) }
        return loaded
    }

    // MARK: work

    /// Speech to text, one token at a time (" word" starts a word), timed in seconds from the start of `samples` (16 kHz mono). Up to
    /// 15 s goes through the model in one pass; longer audio is cut at pauses and stitched (the pass after a call).
    func transcribe(_ samples: [Float]) async throws -> [Segment] {
        let a = try await ready()
        var audio = samples
        let least = 16000 / 2  // the model wants at least 0.3 s
        if audio.count < least { audio += quiet(least - audio.count) }
        return try await exclusive {
            let layers = await a.decoderLayerCount
            var state = try TdtDecoderState(decoderLayers: layers)
            let r = try await a.transcribe(audio, decoderState: &state)
            return (r.tokenTimings ?? []).map { ($0.startTime, $0.endTime, $0.token) }
        }
    }

    /// How sure the voice model is that this 256 ms (4096 samples) holds speech, 0...1, with its running state. nil when the voice model
    /// is not there; the caller then decides by loudness.
    func speech(_ chunk: [Float], _ state: VadStreamState?) async -> (p: Float, state: VadStreamState)? {
        guard let v = locked({ vad }) else { return nil }
        let s: VadStreamState
        if let state { s = state } else { s = await v.makeStreamState() }
        return try? await exclusive {
            let r = try await v.processStreamingChunk(chunk, state: s, config: .default)
            return (r.probability, r.state)
        }
    }

    /// Who speaks when in a whole recording (the pass after a call): turns in seconds from its start, voices "o1", "o2"...
    func diarize(_ samples: [Float], maxSpeakers: Int?) async throws -> [(start: Double, end: Double, spk: String)] {
        let d = OfflineDiarizerManager(config: OfflineDiarizerConfig.default.withSpeakers(max: maxSpeakers))
        try await d.prepareModels()
        let r = try await exclusive { try await d.process(audio: samples) }
        var ids: [String: String] = [:]
        return r.segments.sorted { $0.startTimeSeconds < $1.startTimeSeconds }.map { s in
            if ids[s.speakerId] == nil { ids[s.speakerId] = "o\(ids.count + 1)" }
            return (Double(s.startTimeSeconds), Double(s.endTimeSeconds), ids[s.speakerId]!)
        }
    }
}

/// Room-quiet noise, not digital silence: exact zeros throw off the speaker models' normalisation (FluidAudio #981).
func quiet(_ n: Int) -> [Float] { (0..<n).map { _ in Float.random(in: -0.0001...0.0001) } }
