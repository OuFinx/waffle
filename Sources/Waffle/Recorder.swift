// Records the microphone ("Me") and the sound the Mac plays ("Them": the call) and transcribes both live with the shared speech models
// (Engine). The sound the Mac plays comes from a Core Audio process tap, which needs only the System Audio Recording permission; screen
// capture (ScreenCaptureKit) is the fallback. Every piece of audio is timed by its own timestamps, so "Me" and "Them" line up and a
// busy moment does not cut a sentence. Audio is never written to disk: it lives in memory until recognised, plus a compact copy of the
// speech for the second pass after the call (see Model.polish), dropped then.
import AVFoundation
import AppKit
import CoreAudio
import FluidAudio
import ScreenCaptureKit

private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
private let chunk = 4096  // 256 ms: the voice model's step

/// Epoch ms of a host time (mach ticks) from an audio timestamp; now when there is none.
func wallMs(_ host: UInt64?) -> Double {
    let now = Date().timeIntervalSince1970 * 1000
    guard let host, host > 0 else { return now }
    var tb = mach_timebase_info_data_t()
    mach_timebase_info(&tb)
    let ticks = mach_absolute_time()
    let delta = host <= ticks ? -Double(ticks - host) : Double(host - ticks)
    return now + delta * Double(tb.numer) / Double(tb.denom) / 1_000_000
}

/// What a recording leaves for after the call: the tapes (the microphone's stays empty: only the other side's voices are told apart).
struct Tapes { var mic: Tape; var sys: Tape }

final class Recorder {
    // All callbacks arrive on the main queue.
    var onWindow: (_ src: String, _ w: Int, _ final: Bool, _ segments: [Segment]) -> Void = { _, _, _, _ in }
    var onHearing: (_ src: String, _ on: Bool) -> Void = { _, _ in }
    var onError: (String) -> Void = { _ in }
    /// Who spoke when in the system audio: voices told apart by sound, numbered "1", "2"... for this recording.
    var onTurns: ([Turn]) -> Void = { _ in }

    /// Off: the microphone is not transcribed ("Me" is muted in Waffle only; the call still hears you). The open sentence is finished.
    var micOn: Bool {
        get { flags.withLock { $0.micOn } }
        set { flags.withLock { $0.micOn = newValue } }
    }
    private let flags = Locked(Flags())
    private struct Flags { var micOn = true; var stopped = false; var sysHeard = false; var lastMic = 0.0, lastSys = 0.0 }  // last*: epoch ms where the audio captured so far ends

    private var mic: Source!, sys: Source!
    private var micIn: AsyncStream<Piece>.Continuation!, sysIn: AsyncStream<Piece>.Continuation!
    private var micLoop: Task<Void, Never>?, sysLoop: Task<Void, Never>?
    private let micCapture = MicCapture()
    private let micWatch = Locked(MicWatch())
    private let micResample = Resampler(), sysResample = Resampler()
    private let sysQueue = DispatchQueue(label: "system audio")  // starts, stops and restarts of the system audio, one at a time
    private var tap: SystemTap?
    private var screen: SystemScreen?
    private var sysRetries = 0
    private var sysStarted = Date()
    private var timer: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var lastError = ""

    init() {
        let (ms, mc) = AsyncStream.makeStream(of: Piece.self)
        let (ss, sc) = AsyncStream.makeStream(of: Piece.self)
        micIn = mc; sysIn = sc
        mic = Source("mic", self); sys = Source("sys", self)
        micLoop = Task.detached(priority: .userInitiated) { [mic] in for await p in ms { await mic!.feed(p) } }
        sysLoop = Task.detached(priority: .userInitiated) { [sys] in for await p in ss { await sys!.feed(p) } }
        micCapture.onAudio = { [weak self] buf, host in
            guard let self, self.micOn, let x = self.micResample.convert(buf) else { return }
            let ms = wallMs(host)
            self.flags.withLock { $0.lastMic = ms + Double(x.count) / 16 }
            self.micIn.yield(Piece(samples: x, ms: ms))
        }
        micCapture.onError = { [weak self] in self?.error($0) }
    }

    func start() async {
        // The speaker model downloads once from Hugging Face; until it is there, "Them" has no speaker labels. Nemotron 3 (Sortformer, up to
        // 8 voices, 2.9 s behind): on 16 real meetings of 3 to 9 people, plain and after an Opus 24 kbit/s round trip like a call, it gave
        // the right voice to 86-98% of lines, against 64-91% for LS-EEND, which told apart at most 4.
        if Model.tellVoicesApart { Task.detached(priority: .utility) { [weak self] in
            do {
                let d = Nemotron3Diarizer(config: .fast32, models: try await Nemotron3Models.loadFromHuggingFace(config: .fast32))
                await self?.sys.setDiarizer(d)
            } catch {
                self?.error("Speaker labels are off: \(error.localizedDescription)")
            }
        } }

        if await AVCaptureDevice.requestAccess(for: .audio) {
            guard !isStopped else { return }
            micCapture.start()
        } else {
            error("No microphone access: allow Waffle in System Settings > Privacy & Security > Microphone")
        }
        guard !isStopped else { return }
        if SystemAudioPermission.status == .unknown {  // never asked (the setup asks): ask now, before the tap is made
            _ = await withCheckedContinuation { c in SystemAudioPermission.request { c.resume(returning: $0) } }
        }
        guard !isStopped else { return }
        sysQueue.async { self.startSystem() }
        listen()

        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + 1, repeating: 0.5)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private var isStopped: Bool { flags.withLock { $0.stopped } }

    /// Finishes the last windows, waits for their text, then calls `done` on the main queue (after the last onWindow) with the tapes.
    func stop(done: @escaping (Tapes) -> Void) {
        Task.detached(priority: .userInitiated) { [self] in
            let tapes = await teardown()
            DispatchQueue.main.async { done(tapes) }
        }
    }

    /// Stop without waiting for anything new, for quitting the app.
    func shutdown() {
        flags.withLock { $0.stopped = true }
        timer?.cancel()
        unlisten()
        micCapture.stop()
        sysQueue.async { [self] in tap?.stop(); tap = nil; screen?.stop(); screen = nil }  // not sync: a Core Audio call that hangs must not hold up quitting
    }

    private func teardown() async -> Tapes {
        shutdown()
        micIn.finish(); sysIn.finish()
        await micLoop?.value; await sysLoop?.value
        let m = await mic.finish(), s = await sys.finish()
        return Tapes(mic: m, sys: s)
    }

    // MARK: system audio: the tap, else screen capture; restarted when it stops, the output changes or the Mac wakes

    private func startSystem() {
        guard !isStopped else { return }
        sysStarted = Date()
        flags.withLock { $0.sysHeard = false }
        if SystemAudioPermission.status != .denied {
            let t = SystemTap()
            t.onAudio = { [weak self] in self?.sysAudio($0, $1) }
            t.onWrongRate = { [weak self] in
                log.error("process tap delivers at another rate than its format says: rebuilding it")
                self?.restartSystem()
            }
            do {
                try t.start()
                tap = t
                log.info("system audio: process tap")
                return
            } catch {
                log.error("process tap failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        startScreen()
    }

    /// Sound from the screen capture that runs alongside a silent tap: the tap goes, this takes over.
    private func screenAudio(_ buf: AVAudioPCMBuffer, _ host: UInt64?) {
        if tap != nil, buf.floatChannelData.map({ d in (0..<Int(buf.frameLength)).contains { d[0][$0] != 0 } }) == true {
            sysQueue.async { [self] in if let t = tap { log.info("screen capture brings sound: the tap goes"); t.stop(); tap = nil } }
        }
        if tap == nil { sysAudio(buf, host) }
    }

    private func sysAudio(_ buf: AVAudioPCMBuffer, _ host: UInt64?) {
        guard let x = sysResample.convert(buf) else { return }
        let ms = wallMs(host)
        flags.withLock { f in
            f.lastSys = ms + Double(x.count) / 16
            if !f.sysHeard && x.contains(where: { $0 != 0 }) { f.sysHeard = true }
        }
        sysIn.yield(Piece(samples: x, ms: ms))
    }

    private func startScreen() {
        guard CGPreflightScreenCaptureAccess() else {
            error("No system audio: allow Waffle in System Settings > Privacy & Security > Screen & System Audio Recording (System Audio Recording Only is enough)")
            return
        }
        let s = SystemScreen()
        s.onAudio = { [weak self] in self?.screenAudio($0, $1) }
        s.onStop = { [weak self] e in
            log.error("screen capture stopped: \(e.localizedDescription, privacy: .public)")
            self?.restartSystem()
        }
        screen = s
        Task {
            do {
                try await s.start()
                self.sysQueue.async {
                    if self.isStopped || self.screen !== s { s.stop() } else { log.info("system audio: screen capture") }  // stopped or replaced while it started
                }
            } catch {
                log.error("screen capture failed: \(error.localizedDescription, privacy: .public)")
                self.restartSystem()
            }
        }
    }

    /// Tear the system audio down and start it again, waiting longer each time it fails in a row (0.25 s ... 8 s).
    private func restartSystem(after: Double? = nil) {
        sysQueue.async { [self] in
            tap?.stop(); tap = nil; screen?.stop(); screen = nil
            let wait = after ?? min(8, 0.25 * pow(2, Double(sysRetries)))
            sysRetries += 1
            if sysRetries == 4 { error("System audio stopped: reconnecting...") }
            sysQueue.asyncAfter(deadline: .now() + wait) { [self] in if tap == nil && screen == nil { startSystem() } }
        }
    }

    /// Twice a second: finish windows whose audio stopped coming (nothing plays, or the mic is muted), and bring back a capture that
    /// went quiet without saying so.
    private func tick() {
        guard !isStopped else { return }
        let now = Date().timeIntervalSince1970 * 1000
        let (m, s) = flags.withLock { ($0.lastMic, $0.lastSys) }
        // No audio captured for 0.7 s (screen capture sends none while nothing plays; a muted mic sends none): finish the window.
        Task { if now - m > 700 { await mic.idle() }; if now - s > 700 { await sys.idle() } }
        let stuck = micCapture.stuckFor
        if stuck > 5 {  // an engine call hangs: no restarts pile up behind it, the user is told
            if stuck < 5.5 { log.error("microphone: an engine call hangs for 5 s") }
            error("The microphone does not respond (a device went away?): your side is not transcribed until it does")
        } else if micOn, micCapture.running {
            switch micWatch.withLock({ $0.check(now: now / 1000, sinceAudio: micCapture.silentFor, sinceSound: micCapture.soundlessFor) }) {
            case .restart:
                log.error("microphone delivered nothing for 3 s: restarting it")
                micCapture.restart(after: 0, devicesChanged: true)
            case .giveUp: error("The microphone stopped sending audio: plug it in again or pick another one")
            case .muted: error("Your microphone sends only silence: is it muted?")
            case .wait: break
            }
        }
        sysQueue.async { [self] in
            if Date().timeIntervalSince(sysStarted) > 30, tap != nil || screen != nil { sysRetries = 0 }  // it works: the next failure starts the backoff afresh
            guard let t = tap else { return }
            if t.silentFor > 3 {
                log.error("process tap delivered nothing for 3 s: restarting it")
                restartSystem()
            } else if !flags.withLock({ $0.sysHeard }), Date().timeIntervalSince(sysStarted) > 20, SystemAudioPermission.status != .allowed,
                      CGPreflightScreenCaptureAccess(), screen == nil, !callApps().isEmpty {
                // A call is on, yet the tap gave only digital silence for 20 s and the permission is not known to be there: macOS gives a
                // tap without it exactly that. Screen capture runs alongside; the tap goes once screen capture brings sound.
                log.error("process tap is silent during a call: trying screen capture")
                startScreen()
            }
        }
    }

    /// Headphones plugged in, AirPods connected, the default input or output changed, the Mac woke up: capture again from what is there now.
    private func listen() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, !self.isStopped else { return }
            self.micWatch.withLock { $0 = MicWatch() }  // a microphone given up on may work now
            self.micCapture.restart(after: 0.4, devicesChanged: true)
            self.restartSystem(after: 0.4)
        }
        deviceListener = block
        for sel in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice] {
            var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.global(), block)
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self, !self.isStopped else { return }
            log.info("woke up: restarting capture")
            self.micWatch.withLock { $0 = MicWatch() }
            self.micCapture.restart(after: 1, devicesChanged: true)
            self.restartSystem(after: 1)
        })
    }

    private func unlisten() {
        if let block = deviceListener {
            for sel in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice] {
                var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.global(), block)
            }
            deviceListener = nil
        }
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers = []
    }

    /// The echo check needs to know whether the sound goes to speakers.
    var speakersInUse: Bool { !micCapture.headphones }

    /// The system audio around a wall time, for the echo check (nil if not there yet).
    func reference(endMs: Double, count: Int) async -> [Float]? { await sys.recent(endMs: endMs, count: count) }

    fileprivate func window(_ src: String, _ w: Int, _ final: Bool, _ segs: [Segment]) { DispatchQueue.main.async { self.onWindow(src, w, final, segs) } }
    fileprivate func hearing(_ src: String, _ on: Bool) { DispatchQueue.main.async { self.onHearing(src, on) } }
    fileprivate func turns(_ t: [Turn]) { DispatchQueue.main.async { self.onTurns(t) } }
    fileprivate func error(_ m: String) {
        DispatchQueue.main.async {
            guard m != self.lastError else { return }  // once is enough
            self.lastError = m
            self.onError(m)
        }
    }
}

/// A piece of 16 kHz mono audio and the wall time (epoch ms) of its first sample.
struct Piece: Sendable { let samples: [Float]; let ms: Double }

/// A value behind a lock, for flags read on audio threads.
final class Locked<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ v: T) { value = v }
    func withLock<R>(_ f: (inout T) -> R) -> R { lock.lock(); defer { lock.unlock() }; return f(&value) }
}

/// Any capture format -> 16 kHz mono, with one converter kept as long as the format stays (it carries the filter state across buffers).
final class Resampler {
    private var converter: AVAudioConverter?
    private let lock = NSLock()

    func convert(_ buf: AVAudioPCMBuffer) -> [Float]? {
        lock.lock(); defer { lock.unlock() }
        if converter?.inputFormat != buf.format {
            converter = AVAudioConverter(from: buf.format, to: target)
            converter?.downmix = true
        }
        guard let conv = converter, buf.frameLength > 0 else { return nil }
        let cap = AVAudioFrameCount(Double(buf.frameLength) * 16000 / buf.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return nil }
        var given = false
        conv.convert(to: out, error: nil) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true; status.pointee = .haveData; return buf
        }
        guard out.frameLength > 0, let data = out.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
    }
}

// MARK: one speaker, from audio to text

/// One speaker's audio from capture to text, in order: the stream's clock, voice detection, the echo check, the live windows and their
/// recognition passes (one after another), the tape for later, and for the system audio the live speaker labels.
actor Source {
    let name: String
    private unowned let rec: Recorder
    private let windower = Windower()
    private var clock = ClockMap()
    private var fed = 0  // samples handed to the windows so far: the stream's sample count
    private var pending: [Float] = []
    private var vad: VadStreamState?
    private lazy var voiceLevel = VoiceLevel(most: name == "mic" ? 8 : 20)
    private var speaking = false, hearing = false
    private var passes: Task<Void, Never>?  // the last recognition pass; each waits for the one before
    private var busy = false  // a piece is being worked on
    private var failed = false
    private var tape = Tape()
    // Recent audio for the echo check (system audio only): the pieces of the last 5 s, as they came.
    private var recentPieces: [Piece] = []
    // Live speaker labels (system audio only): its own clock, as it is fed room noise for gaps of at most 2 s.
    private var diarizer: Nemotron3Diarizer?
    private var diarClock = ClockMap()
    private var diarFed = 0
    private var diarFrames = 0  // 10 ms frames the diarizer gave back so far
    private var diarPending: [Float] = []

    init(_ name: String, _ rec: Recorder) { self.name = name; self.rec = rec }

    func setDiarizer(_ d: Nemotron3Diarizer) { diarizer = d }

    func feed(_ p: Piece) async {
        busy = true
        defer { busy = false }
        if name == "sys" {
            recentPieces.append(p)
            while let f = recentPieces.first, p.ms - f.ms > 5000 { recentPieces.removeFirst() }
        }
        let at = fed + pending.count
        if !clock.anchors.isEmpty, p.ms - clock.ms(at) > 300 {
            // Nothing came for a while (nothing played, the mic was muted, the Mac slept): the window before is done.
            await drain()
            run(windower.flush())
            clock.mark(sample: fed, ms: p.ms, tolerance: 0)
        } else {
            clock.mark(sample: at, ms: p.ms)  // first piece, or a clock that drifted: re-anchor
        }
        pending += p.samples
        while pending.count >= chunk {
            let x = Array(pending[..<chunk])
            pending.removeFirst(chunk)
            await process(x)
        }
    }

    private func process(_ input: [Float]) async {
        let ms = clock.ms(fed)
        var x = input
        if name == "mic", rec.speakersInUse, let ref = await rec.reference(endMs: ms + 256, count: chunk + 4800), echoLike(x, ref, maxLag: 4800) {
            x = quiet(chunk)  // the speakers coming back into the mic, past echo cancellation
        }
        let (heard, rms) = voiceLevel.adjust(x)  // quiet speakers heard as well as loud ones
        let p: Float
        if let r = await Engine.shared.speech(heard, vad) {
            vad = r.state; p = r.p
        } else {
            p = rms > max(0.0015, voiceLevel.floor * 3) ? 1 : 0  // the voice model is not loaded yet: loudness
        }
        speaking = speaking ? p >= 0.35 : p >= 0.5
        if speaking && !hearing { hearing = true; rec.hearing(name, true) }
        if name == "sys" { tape.add(x, ms: ms, speech: speaking) }  // for telling the voices apart after the call
        fed += x.count
        if name == "sys" { await diarize(x, ms) }
        run(windower.push(x, speech: speaking))
    }

    /// Recognise passes one after another; their text goes out in order.
    private func run(_ ps: [Pass]) {
        for p in ps {
            let before = passes
            passes = Task { [weak self] in
                await before?.value
                guard let self else { return }
                var pass = p, tokens: [Segment]?
                do {
                    tokens = try await Engine.shared.transcribe(p.audio)
                    // Too few words for the speech: try without the context, keep what heard more (see Windower.thin).
                    if let t = tokens, await self.thin(p, t), let bare = try? await Engine.shared.transcribe(p.bare.audio),
                       await self.words(p.bare, bare) > Int(Double(await self.words(p, t)) * 1.3) {
                        pass = p.bare; tokens = bare
                        await self.forget(p)
                    }
                } catch {
                    tokens = nil
                    await self.fail(error)
                }
                await self.finished(pass, tokens)
            }
        }
    }

    private func thin(_ p: Pass, _ t: [Segment]) -> Bool { windower.thin(p, t) }
    private func words(_ p: Pass, _ t: [Segment]) -> Int { windower.words(p, t) }
    private func forget(_ p: Pass) { windower.forgetContext(p) }

    private func fail(_ e: Error) {
        guard !failed else { return }
        failed = true
        rec.error("Speech recognition: \(e.localizedDescription)")
    }

    private func finished(_ p: Pass, _ tokens: [Segment]?) {
        let out = windower.done(p, tokens)
        for e in out { rec.window(name, Int(clock.ms(e.start)), e.final, e.segments) }
        if hearing && !out.isEmpty { hearing = false; rec.hearing(name, false) }
    }

    /// No audio was captured for a while: what came is the end of it (the last bit padded to a chunk), the window is done. Not while a
    /// piece is being worked on: then audio is coming, just slowly.
    func idle() async {
        guard !busy, !clock.anchors.isEmpty, windower.active || !pending.isEmpty else { return }
        busy = true
        await drain()
        run(windower.flush())
        busy = false
        if hearing { hearing = false; rec.hearing(name, false) }
    }

    /// The audio short of a whole chunk, padded with room noise.
    private func drain() async {
        guard !pending.isEmpty else { return }
        let x = pending + quiet(chunk - pending.count)
        pending = []
        await process(x)
    }

    /// The recording ends: the rest of the audio, the last window's text, the last speaker labels. Returns the tape.
    func finish() async -> Tape {
        await drain()
        run(windower.flush())
        await passes?.value
        if let d = diarizer {
            let rest = diarPending
            diarPending = []
            let r = try? await Engine.shared.exclusive { () throws -> [Nemotron3ChunkResult] in
                d.appendAudio(rest)
                return try d.finishStream()
            }
            emit(r)
            diarizer = nil
        }
        let t = tape
        tape = Tape()
        return t
    }

    /// The system audio from `count` samples before `endMs` to it, if it came in already.
    func recent(endMs: Double, count: Int) -> [Float]? {
        let from = endMs - Double(count) / 16
        guard let first = recentPieces.first, first.ms <= from, let last = recentPieces.last, last.ms + Double(last.samples.count) / 16 >= endMs else { return nil }
        var out: [Float] = []
        out.reserveCapacity(count)
        for p in recentPieces where p.ms + Double(p.samples.count) / 16 > from && p.ms < endMs {
            let a = max(0, Int((from - p.ms) * 16)), b = min(p.samples.count, Int((endMs - p.ms) * 16))
            if a < b { out += p.samples[a..<b] }
        }
        guard out.count >= count - 160 else { return nil }  // a gap in it
        return out.count >= count ? Array(out.suffix(count)) : [Float](repeating: 0, count: count - out.count) + out
    }

    private func diarize(_ x: [Float], _ ms: Double) async {
        guard let d = diarizer else { return }
        if diarClock.anchors.isEmpty { diarClock.mark(sample: 0, ms: ms) }
        let gap = ms - diarClock.ms(diarFed + diarPending.count)
        if gap > 300 {
            diarPending += quiet(min(Int(gap * 16), 32000))  // room noise, never exact zeros (FluidAudio #981)
            diarClock.mark(sample: diarFed + diarPending.count, ms: ms, tolerance: 0)
        }
        diarPending += x.map { $0 + Float.random(in: -0.0001...0.0001) }
        guard diarPending.count >= 8000 else { return }
        let a = diarPending
        diarPending = []
        diarFed += a.count
        let r = try? await Engine.shared.exclusive { () throws -> [Nemotron3ChunkResult] in
            d.appendAudio(a)
            return try d.processBufferedAudio()
        }
        emit(r)
    }

    /// Diarizer chunks (2.56 s of 10 ms frames each) -> turns on the wall clock, each chunk on its own: a voice that talks on is a run
    /// of turns. Voices are "1", "2"... for this recording.
    private func emit(_ chunks: [Nemotron3ChunkResult]?) {
        var turns: [Turn] = []
        for c in chunks ?? [] {
            let at = Double(diarFrames) / 100
            for s in Nemotron3Diarizer.segments(probabilities: c.probabilities, frameCount: c.frameCount, numSpeakers: c.numSpeakers) {
                turns.append(Turn(start: Int(diarClock.ms(Int((at + Double(s.startSeconds)) * 16000))), end: Int(diarClock.ms(Int((at + Double(s.endSeconds)) * 16000))), spk: String(s.speakerIndex + 1)))
            }
            diarFrames += c.frameCount
        }
        if !turns.isEmpty { rec.turns(turns) }
    }
}

// MARK: the microphone

/// The microphone through a fresh AVAudioEngine each time the devices change: a reused engine can stay "running" on a device that is
/// gone and capture nothing. Apple's voice processing cancels what the speakers play (measured at 70% volume: 71% of the played words
/// reached the mic without it, 15% with it), unless the sound goes to headphones, where there is no echo and it only dulls the voice.
/// Every engine call runs on `q` and may never return: AVAudioEngine.inputNode can hang for hours when a Bluetooth device goes away. So
/// nothing ever waits on `q`; each build carries a generation, a newer request or a stop makes an older build's late result void, and
/// stuckFor tells the watchdog that a build hangs.
final class MicCapture {
    var onAudio: (AVAudioPCMBuffer, UInt64?) -> Void = { _, _ in }
    var onError: (String) -> Void = { _ in }
    private let q = DispatchQueue(label: "mic")
    // Only on q:
    private var engine: AVAudioEngine?
    private var observer: NSObjectProtocol?
    private var noVoiceProcessing = false  // it failed on this pair of devices: the plain mic until the devices change
    // From any thread:
    private let state = Locked(State())
    private struct State { var gen = 0; var stopped = false; var busySince: Date? }
    private let last = Locked(Date()), lastSound = Locked(Date())
    private let phones = Locked(false)

    /// Seconds since the last audio, and since the last audio that was not mostly exact zeros.
    var silentFor: TimeInterval { Date().timeIntervalSince(last.withLock { $0 }) }
    var soundlessFor: TimeInterval { Date().timeIntervalSince(lastSound.withLock { $0 }) }
    /// Seconds the work on `q` has been going (0: none): long means an engine call hangs.
    var stuckFor: TimeInterval { state.withLock { $0.busySince.map { Date().timeIntervalSince($0) } ?? 0 } }
    /// Started and not given up (no microphone found): the watchdog may restart it.
    var running: Bool { live.withLock { $0 } }
    private let live = Locked(false)
    /// The sound goes to headphones (see headphonesInUse).
    var headphones: Bool { phones.withLock { $0 } }

    func start() { live.withLock { $0 = true }; restart(after: 0) }

    /// Build the engine again after `after` seconds; calls in between count once.
    func restart(after: Double = 0.3, devicesChanged: Bool = false) {
        let g = state.withLock { s -> Int? in
            guard !s.stopped else { return nil }
            s.gen += 1
            return s.gen
        }
        guard let g else { return }
        let now = Date()
        last.withLock { $0 = now }; lastSound.withLock { $0 = now }
        run(g, after: after) { [self] in
            if devicesChanged { noVoiceProcessing = false }
            teardown()
            build(g)
        }
    }

    /// Never waits: a hanging build must not hold up ending the meeting or quitting. The engine goes once `q` is free.
    func stop() {
        state.withLock { $0.stopped = true; $0.gen += 1 }
        live.withLock { $0 = false }
        q.async { [self] in teardown() }
    }

    private func current(_ g: Int) -> Bool { state.withLock { $0.gen == g } }

    /// Work for generation `g` on `q`, skipped if a newer request or a stop came while it waited (behind a hanging build, say).
    private func run(_ g: Int, after: Double, _ work: @escaping () -> Void) {
        q.asyncAfter(deadline: .now() + after) { [self] in
            guard current(g) else { return }
            state.withLock { $0.busySince = Date() }
            defer { state.withLock { $0.busySince = nil } }
            work()
        }
    }

    private func teardown() {
        if let o = observer { NotificationCenter.default.removeObserver(o); observer = nil }
        if let e = engine { e.inputNode.removeTap(onBus: 0); e.stop() }
        engine = nil
    }

    private func build(_ g: Int, tries: Int = 0) {
        let e = AVAudioEngine()
        let input = e.inputNode  // where it hangs, if it does
        guard current(g) else { return }  // it came back after a newer request or a stop: its result is void
        let hp = headphonesInUse()
        phones.withLock { $0 = hp }
        let vp = !noVoiceProcessing && !hp
        if vp {
            do { try input.setVoiceProcessingEnabled(true) } catch { log.error("voice processing: \(error.localizedDescription, privacy: .public)") }
            // It also ducks other apps' audio by default, which would make the call quieter: keep that off.
            input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
        }
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else {  // a device is coming or going: look again in a moment
            if tries < 10 { run(g, after: 1) { [weak self] in self?.build(g, tries: tries + 1) } } else { live.withLock { $0 = false }; onError("No microphone found") }
            return
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { [weak self] buf, when in
            guard let self, self.current(g) else { return }
            let one = oneChannel(buf), now = Date()
            self.last.withLock { $0 = now }
            if let d = one.floatChannelData, !mostlyZeros(UnsafeBufferPointer(start: d[0], count: Int(one.frameLength))) { self.lastSound.withLock { $0 = now } }
            self.onAudio(one, when.isHostTimeValid ? when.hostTime : nil)
        }
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: e, queue: nil) { [weak self] _ in self?.restart() }
        engine = e
        do {
            try e.start()
            guard current(g) else { return teardown() }  // a newer request or a stop came while it started
            live.withLock { $0 = true }  // back, also after "No microphone found"
            log.info("microphone: \(fmt.sampleRate) Hz, \(fmt.channelCount) ch, voice processing \(vp), headphones \(hp)")
        } catch {
            log.error("microphone start: \(error.localizedDescription, privacy: .public)")
            teardown()
            if vp {
                noVoiceProcessing = true  // e.g. AirPods mic with the Mac's speakers: voice processing can not pair them
                build(g, tries: tries)
            } else {
                onError("Microphone: \(error.localizedDescription)")
            }
        }
    }
}

/// Voice processing hands over several copies of the mic (3 to 9, by Mac) with no channel layout, and AVAudioConverter turns that into
/// silence when it downmixes: keep one channel, the first unless it is silent and another is not.
private func oneChannel(_ buf: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
    guard buf.format.channelCount > 1, let data = buf.floatChannelData,
          let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: buf.format.sampleRate, channels: 1, interleaved: false),
          let out = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: buf.frameLength) else { return buf }
    let n = Int(buf.frameLength)
    func energy(_ c: Int) -> Float { var e: Float = 0; for i in stride(from: 0, to: n, by: 8) { e += abs(data[c][i]) }; return e }
    var ch = 0
    if energy(0) == 0, let loud = (1..<Int(buf.format.channelCount)).max(by: { energy($0) < energy($1) }), energy(loud) > 0 { ch = loud }
    out.frameLength = buf.frameLength
    out.floatChannelData![0].update(from: data[ch], count: n)
    return out
}

// MARK: devices

private func prop<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ initial: T, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T {
    var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var v = initial, size = UInt32(MemoryLayout<T>.size)
    AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &v)
    return v
}

/// The Mac's sound goes to headphones: AirPods or another Bluetooth headset (not one that calls itself a speaker), the headphone jack,
/// or a USB or other device whose output says it is headphones.
func headphonesInUse() -> Bool {
    let out: AudioObjectID = prop(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, AudioObjectID(kAudioObjectUnknown))
    guard out != kAudioObjectUnknown else { return false }
    let transport: UInt32 = prop(out, kAudioDevicePropertyTransportType, 0)
    if transport == UInt32(kAudioDeviceTransportTypeBluetooth) || transport == UInt32(kAudioDeviceTransportTypeBluetoothLE) {
        let name = (prop(out, kAudioObjectPropertyName, "" as CFString) as String).lowercased()
        return !["speaker", "boom", "soundlink", "homepod", "колонк"].contains { name.contains($0) }
    }
    if transport == UInt32(kAudioDeviceTransportTypeBuiltIn) {
        let source: UInt32 = prop(out, kAudioDevicePropertyDataSource, 0, scope: kAudioObjectPropertyScopeOutput)
        return source == 0x6864_706E  // 'hdpn': the headphone jack
    }
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(out, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
    var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
    AudioObjectGetPropertyData(out, &addr, 0, nil, &size, &streams)
    return streams.contains { prop($0, kAudioStreamPropertyTerminalType, UInt32(0)) == UInt32(kAudioStreamTerminalTypeHeadphones) }
}

// MARK: the sound the Mac plays: a Core Audio process tap

/// The System Audio Recording permission, through the TCC calls the system uses (no public API tells it yet).
enum SystemAudioPermission {
    enum Status { case allowed, denied, unknown }
    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias Request = @convention(c) (CFString, CFDictionary?, @escaping (Bool) -> Void) -> Void
    private static let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    static var status: Status {
        guard let tcc, let f = dlsym(tcc, "TCCAccessPreflight") else { return .unknown }
        switch unsafeBitCast(f, to: Preflight.self)("kTCCServiceAudioCapture" as CFString, nil) {
        case 0: return .allowed
        case 1: return .denied
        default: return .unknown
        }
    }

    /// Shows the system's question if it was never answered; `done` gets the answer on the main queue.
    static func request(_ done: @escaping (Bool) -> Void) {
        guard let tcc, let f = dlsym(tcc, "TCCAccessRequest") else { return done(false) }
        unsafeBitCast(f, to: Request.self)("kTCCServiceAudioCapture" as CFString, nil) { ok in DispatchQueue.main.async { done(ok) } }
    }
}

/// Everything the Mac plays except Waffle's own sound, through a Core Audio process tap (macOS 14.2+) in a private aggregate device. It
/// needs only System Audio Recording (no screen recording, no purple indicator, no monthly question) and carries the audio's own
/// timestamps. Bound to the output devices there are when it starts: the Recorder rebuilds it when the output changes, and when the
/// rate it delivers is not the one its format said (onWrongRate: the device changed its rate in place, see RateCheck).
final class SystemTap {
    var onAudio: (AVAudioPCMBuffer, UInt64?) -> Void = { _, _ in }
    var onWrongRate: () -> Void = {}
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let q = DispatchQueue(label: "tap", qos: .userInitiated)
    private let last = Locked(Date())
    private var rate = RateCheck(rate: 0)  // only on q

    var silentFor: TimeInterval { Date().timeIntervalSince(last.withLock { $0 }) }

    func start() throws {
        func fail(_ what: String, _ err: OSStatus) -> NSError {
            stop()
            return NSError(domain: "Waffle", code: Int(err), userInfo: [NSLocalizedDescriptionKey: "\(what) (\(err))"])
        }
        var me = AudioObjectID(kAudioObjectUnknown), pid = getpid(), size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &me)
        let desc = CATapDescription(monoGlobalTapButExcludeProcesses: me == kAudioObjectUnknown ? [] : [me])
        desc.uuid = UUID()
        desc.name = "Waffle"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        var err = AudioHardwareCreateProcessTap(desc, &tapID)
        guard err == noErr, tapID != kAudioObjectUnknown else { throw fail("Could not tap the system audio", err) }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Waffle System Audio",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: desc.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
        ]
        err = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard err == noErr else { throw fail("Could not make the system audio device", err) }

        var asbd = AudioStreamBasicDescription()
        size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        err = AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd)
        guard err == noErr, asbd.mSampleRate > 0, let format = AVAudioFormat(streamDescription: &asbd) else { throw fail("The system audio has no format", err) }
        rate = RateCheck(rate: asbd.mSampleRate)

        err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, q) { [weak self] _, input, inputTime, _, _ in
            self?.deliver(input, inputTime.pointee, format)
        }
        guard err == noErr, procID != nil else { throw fail("Could not read the system audio", err) }
        last.withLock { $0 = Date() }
        err = AudioDeviceStart(aggregateID, procID)
        guard err == noErr else { throw fail("Could not start the system audio", err) }
    }

    private func deliver(_ input: UnsafePointer<AudioBufferList>, _ time: AudioTimeStamp, _ format: AVAudioFormat) {
        let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let bytes = Int(format.streamDescription.pointee.mBytesPerFrame)
        guard bytes > 0, let first = src.first, first.mDataByteSize > 0 else { return }
        let frames = AVAudioFrameCount(Int(first.mDataByteSize) / bytes)
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buf.frameLength = frames
        let dst = UnsafeMutableAudioBufferListPointer(buf.mutableAudioBufferList)
        guard dst.count == src.count else { return }
        for i in 0..<src.count {
            guard let s = src[i].mData, let d = dst[i].mData else { continue }
            let n = min(Int(src[i].mDataByteSize), Int(dst[i].mDataByteSize))
            memcpy(d, s, n)
            dst[i].mDataByteSize = UInt32(n)
        }
        last.withLock { $0 = Date() }
        let host = time.mFlags.contains(.hostTimeValid) ? time.mHostTime : nil
        if let host, rate.add(Int(frames), at: Double(AudioConvertHostTimeToNanos(host)) / 1e9) { onWrongRate() }
        onAudio(buf, host)
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let p = procID { _ = AudioDeviceStop(aggregateID, p); _ = AudioDeviceDestroyIOProcID(aggregateID, p) }
            _ = AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { _ = AudioHardwareDestroyProcessTap(tapID) }
        procID = nil; aggregateID = AudioObjectID(kAudioObjectUnknown); tapID = AudioObjectID(kAudioObjectUnknown)
    }
}

// MARK: the sound the Mac plays: screen capture, the fallback

/// System audio through ScreenCaptureKit, for when the tap does not work. It needs Screen & System Audio Recording, and stops with an
/// error when the display goes, the Mac sleeps or the system stops it: onStop then lets the Recorder start it again.
final class SystemScreen: NSObject, SCStreamOutput, SCStreamDelegate {
    var onAudio: (AVAudioPCMBuffer, UInt64?) -> Void = { _, _ in }
    var onStop: (Error) -> Void = { _ in }
    private var stream: SCStream?
    private var cancelled = false  // stopped before it finished starting
    private let q = DispatchQueue(label: "screen audio")

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
            throw NSError(domain: "Waffle", code: 3, userInfo: [NSLocalizedDescriptionKey: "No display to capture the sound of"])
        }
        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.excludesCurrentProcessAudio = true
        cfg.width = 2; cfg.height = 2  // only audio is wanted, keep the video part as cheap as possible
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let s = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: q)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: q)  // ignored, avoids "dropping frame" log spam
        try await s.startCapture()
        stream = s
        if cancelled { stop() }
    }

    func stop() {
        cancelled = true
        guard let s = stream else { return }
        stream = nil
        try? s.removeStreamOutput(self, type: .audio)
        try? s.removeStreamOutput(self, type: .screen)
        s.stopCapture { _ in }
    }

    func stream(_ s: SCStream, didStopWithError error: Error) {
        guard s === stream else { return }
        stream = nil
        onStop(error)
    }

    func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let fd = sb.formatDescription else { return }
        let fmt = AVAudioFormat(cmAudioFormatDescription: fd)
        let n = AVAudioFrameCount(sb.numSamples)
        guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n) else { return }
        buf.frameLength = n
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(n), into: buf.mutableAudioBufferList) == noErr else { return }
        let pts = sb.presentationTimeStamp
        onAudio(buf, pts.isValid ? CMClockConvertHostTimeToSystemUnits(pts) : nil)
    }
}

// MARK: who else is using the microphone (Zoom, Chrome with Meet, FaceTime...)

/// The calls going on: the apps holding the microphone that are calls (see callAppName), by name, with their process ids.
func callProcesses() -> [(name: String, pid: pid_t)] {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    let system = AudioObjectID(kAudioObjectSystemObject)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids)
    var out: [(name: String, pid: pid_t)] = []
    for id in ids where prop(id, kAudioProcessPropertyIsRunningInput, UInt32(0)) != 0 {
        let pid: pid_t = prop(id, kAudioProcessPropertyPID, 0)
        guard pid != getpid() else { continue }
        let bundle = prop(id, kAudioProcessPropertyBundleID, "" as CFString) as String
        var path = [CChar](repeating: 0, count: 4096)
        proc_pidpath(pid, &path, UInt32(path.count))
        if let name = callAppName(bundle: bundle, path: String(cString: path), name: NSRunningApplication(processIdentifier: pid)?.localizedName) { out.append((name, pid)) }
    }
    return out
}

/// Names of the calls going on, once each, sorted.
func callApps() -> [String] { Set(callProcesses().map(\.name)).sorted() }
