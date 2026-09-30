// Records the microphone (AVAudioEngine, "Me") and system audio (ScreenCaptureKit, "Them") and transcribes both in-process with
// Parakeet TDT 0.6B v3 (25 European languages, auto-detected, never translates). Audio is never written to disk.
import AVFoundation
import CParakeet
import CoreAudio
import FluidAudio
import ScreenCaptureKit

private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
// ggml needs its backends loaded before the first model load, once per process (else GGML_ASSERT(device)).
private let backends: Void = { parakeet_log_set({ _, _, _ in }, nil); ggml_backend_load_all() }()

final class Recorder {
    // All callbacks arrive on the main queue.
    var onWindow: (_ src: String, _ w: Int, _ final: Bool, _ segments: [Segment]) -> Void = { _, _, _, _ in }
    var onHearing: (_ src: String, _ on: Bool) -> Void = { _, _ in }
    var onError: (String) -> Void = { _ in }
    /// Who spoke when in the system audio: voices told apart by sound, numbered "1", "2"... for this recording.
    var onTurns: ([Turn]) -> Void = { _ in }
    /// Off: the microphone is not transcribed ("Me" is muted in Waffle only; the call still hears you). The open sentence is finished.
    var micOn = true

    // One model context used from one serial queue, so the two speakers never run it at once. ~0.02-0.35 s of GPU per pass.
    fileprivate let asrQueue = DispatchQueue(label: "asr", qos: .utility)
    private var asr: OpaquePointer?
    private var mic: Segmenter!, sys: Segmenter!
    private let engine = AVAudioEngine()
    private var stream: SCStream?
    private var sysOut: SysOutput!
    private var configObserver: NSObjectProtocol?
    private var idleTimer: DispatchSourceTimer?
    private var stopped = false
    // Speaker diarization of the system audio: FluidAudio's streaming LS-EEND, all on its own queue. Its clock is the audio it was fed,
    // so gaps (system audio stops while nothing plays) are fed as silence to keep it on the wall clock.
    private let diarQueue = DispatchQueue(label: "diarize", qos: .utility)
    private var diarizer: LSEENDDiarizer?
    private var diarStart = 0.0, diarFed = 0  // wall time of the first fed sample, samples fed since

    init() {
        mic = Segmenter("mic", self); sys = Segmenter("sys", self); sysOut = SysOutput(self)
        sys.tap = { [weak self] samples, at in self?.diarQueue.async { self?.diarFeed(samples, at) } }
    }

    func start(model: String) async {
        _ = backends
        var params = parakeet_context_default_params()
        params.use_gpu = true
        // Load on the model's queue and start capturing right away: a cold load can take a while, and the first passes simply queue behind it.
        asrQueue.async { [self] in
            asr = parakeet_init_from_file_with_params(model, params)
            if asr == nil { error("Could not load the speech model \(model)") }
        }

        // The diarizer model downloads once from Hugging Face; until it is there, "Them" has no speaker labels.
        // The AMI variant measured best on a real meeting, also after an Opus 24 kbit/s round trip like a call (17.9% DER against
        // 35-41% for the others). ponytail: it tells apart at most 4 voices; bigger calls merge some. dihard3 allows 10, at 41% DER.
        Task.detached(priority: .utility) { [weak self] in
            do {
                let d = try await LSEENDDiarizer(variant: .ami, stepSize: .step500ms)
                self?.diarQueue.async { self?.diarizer = d }
            } catch {
                self?.error("Speaker labels are off: \(error.localizedDescription)")
            }
        }

        if await AVCaptureDevice.requestAccess(for: .audio) {
            startMic()
            // Headphones plugged in or AirPods connected: the engine stops, so reattach to the new device.
            configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in self?.startMic() }
        } else {
            error("No microphone access: allow Waffle in System Settings > Privacy & Security > Microphone")
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let cfg = SCStreamConfiguration()
            cfg.capturesAudio = true
            cfg.excludesCurrentProcessAudio = true
            cfg.width = 2; cfg.height = 2  // only audio is wanted, keep the video part as cheap as possible
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            let s = SCStream(filter: SCContentFilter(display: content.displays[0], excludingWindows: []), configuration: cfg, delegate: sysOut)
            let q = DispatchQueue(label: "sys")
            try s.addStreamOutput(sysOut, type: .audio, sampleHandlerQueue: q)
            try s.addStreamOutput(sysOut, type: .screen, sampleHandlerQueue: q)  // ignored, avoids "dropping frame" log spam
            try await s.startCapture()
            stream = s
        } catch {
            self.error("No system audio (\(error.localizedDescription)). Allow Waffle in System Settings > Privacy & Security > Screen & System Audio Recording, then restart Waffle")
        }

        // System audio stops delivering buffers while nothing plays: finalise windows whose buffers stopped.
        let t = DispatchSource.makeTimerSource(queue: .global())
        t.schedule(deadline: .now(), repeating: 0.5)
        t.setEventHandler { [weak self] in self?.mic.flushIfIdle(); self?.sys.flushIfIdle() }
        t.resume()
        idleTimer = t
    }

    private func startMic() {
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        // Apple's voice processing cancels what the speakers play (the call, music), so "Me" is only the person at the Mac. Measured at 70%
        // volume: 71% of the played words reached the mic without it, 15% with it (the first and last moments; dropEcho catches those).
        // It also ducks other apps' audio by default, which would make the call quieter: keep that off. The tap then gets 9 identical channels.
        if !input.isVoiceProcessingEnabled {
            do { try input.setVoiceProcessingEnabled(true) } catch { self.error("Echo cancellation is off: \(error.localizedDescription)") }
        }
        input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
        input.installTap(onBus: 0, bufferSize: 4096, format: input.outputFormat(forBus: 0)) { [weak self] buf, _ in
            if self?.micOn == true { self?.mic.feed(firstChannel(buf)) }  // muted: no buffers, so flushIfIdle finalises what was said
        }
        do { try engine.start() } catch { self.error("Microphone: \(error.localizedDescription)") }
    }

    fileprivate func feedSystem(_ buf: AVAudioPCMBuffer) { sys.feed(buf) }

    /// Finalises the last windows, waits for their text, frees the model, then calls `done` on the main queue (after the last onWindow).
    func stop(done: @escaping () -> Void) {
        DispatchQueue.global().async { [self] in
            teardown(flush: true)
            DispatchQueue.main.async(execute: done)
        }
    }

    /// Stop without waiting for anything new, for quitting the app.
    func shutdown() { teardown(flush: false) }

    private func teardown(flush: Bool) {
        guard !stopped else { return }
        stopped = true
        if let o = configObserver { NotificationCenter.default.removeObserver(o) }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        idleTimer?.cancel()
        let s = stream, sem = DispatchSemaphore(value: 0)
        if let s { s.stopCapture { _ in sem.signal() }; _ = sem.wait(timeout: .now() + 2) }
        if flush { mic.flush(); sys.flush() }
        diarQueue.sync {  // the last turns go out before stop's done callback
            if flush, let d = diarizer { emit(try? d.finalizeSession()) }
            diarizer = nil
        }
        asrQueue.sync {
            if let a = asr { parakeet_free(a) }  // ggml asserts at exit if the GPU buffers are still alive
            asr = nil
        }
    }

    /// On diarQueue: feed system audio to the diarizer as it comes, with silence for the gaps.
    private func diarFeed(_ samples: [Float], _ at: Double) {
        guard let d = diarizer else { return }  // not loaded yet: those seconds get no speaker labels
        if diarFed == 0 { diarStart = at }
        let gap = Int((at - (diarStart + Double(diarFed) / 16000)) * 16000)
        if gap > 16000 * 3 / 10 {
            let fill = min(gap, 16000 * 60 * 30)  // ponytail: at most 30 min of silence per gap; longer ones shift the labels a little
            try? d.addAudio([Float](repeating: 0, count: fill), sourceSampleRate: 16000)
            diarFed += fill
        }
        try? d.addAudio(samples, sourceSampleRate: 16000)
        diarFed += samples.count
        emit(try? d.process())
    }

    /// Diarizer segments -> turns on the wall clock. Voices are "0", "1"... for this recording.
    private func emit(_ update: DiarizerTimelineUpdate??) {
        guard let segs = update??.finalizedSegments, !segs.isEmpty else { return }
        let base = diarStart * 1000
        let turns = segs.map { Turn(start: Int(base + Double($0.startTime) * 1000), end: Int(base + Double($0.endTime) * 1000), spk: String($0.speakerIndex + 1)) }
        DispatchQueue.main.async { self.onTurns(turns) }
    }

    /// nil once the model is freed (a straggling buffer after stop).
    fileprivate func transcribe(_ samples: [Float]) -> [Segment]? {
        guard let asr else { return nil }
        var p = parakeet_full_default_params(PARAKEET_SAMPLING_GREEDY)
        p.n_threads = 2
        guard samples.withUnsafeBufferPointer({ parakeet_full(asr, p, $0.baseAddress, Int32($0.count)) }) == 0 else { return [] }
        // One entry per token ("▁" marks a word start), so sentences can be timed and cut exactly. t0/t1 are in 10 ms units.
        return (0..<parakeet_full_n_segments(asr)).flatMap { s in
            (0..<parakeet_full_n_tokens(asr, s)).map { i in
                let d = parakeet_full_get_token_data(asr, s, i)
                return (Double(d.t0) / 100, Double(d.t1) / 100, String(cString: parakeet_full_get_token_text(asr, s, i)).replacingOccurrences(of: "▁", with: " "))
            }
        }
    }

    fileprivate func window(_ src: String, _ w: Int, _ final: Bool, _ segs: [Segment]) { DispatchQueue.main.async { self.onWindow(src, w, final, segs) } }
    fileprivate func hearing(_ src: String, _ on: Bool) { DispatchQueue.main.async { self.onHearing(src, on) } }
    private func error(_ m: String) { DispatchQueue.main.async { self.onError(m) } }
}

/// Voice processing hands over 9 copies of the mic with no channel layout, and AVAudioConverter turns that into silence when it downmixes:
/// keep channel 0 only.
private func firstChannel(_ buf: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
    guard buf.format.channelCount > 1, let data = buf.floatChannelData,
          let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: buf.format.sampleRate, channels: 1, interleaved: false),
          let out = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: buf.frameLength) else { return buf }
    out.frameLength = buf.frameLength
    out.floatChannelData![0].update(from: data[0], count: Int(buf.frameLength))
    return out
}

/// Keeps a growing window of audio per speaker and re-transcribes it every few seconds, so words show up fast and get corrected as
/// context grows (Parakeet: 51% of words right on 2 s pieces, 95% on 15-30 s). Finished sentences are locked and cut off the window, so text on screen is never rewritten later (say, into another language when the speaker switches). At a pause after
/// ~15 s the rest of the window is finalised and a new one starts. Re-running 30 s of audio costs ~0.35 s of GPU.
private final class Segmenter {
    // ponytail: pause detection is relative loudness, these numbers are the calibration knobs
    let frame = 480                   // 30 ms at 16 kHz
    let updateAfter = 16000 * 3 / 2   // re-transcribe at a 300 ms pause once this much new audio came in
    let updatePause = 10
    let updateMax = 16000 * 4         // ...and at least this often while people keep talking
    let commitAfter = 16000 * 15      // at a pause past this length the window becomes final
    let commitPause = 10
    let windowMax = 16000 * 30        // never hold more than this
    let silence: Float = 0.003        // a window that never got louder than this is dropped
    let voice: Float = 0.02           // ponytail: louder than room noise, quieter than speech; the calibration knob for the typing dots

    let src: String
    unowned let rec: Recorder
    var converter: AVAudioConverter?
    var pending: [Float] = [], window: [Float] = []
    var t0 = 0.0, clock = 0      // wall time of the first sample, samples seen since
    var windowStart = 0, sinceUpdate = 0, quietRun = 0, frames = 0
    var sumRms: Float = 0, peak: Float = 0
    var lastFeed = 0.0
    var updating = false         // a non-final pass is queued; skip new ones until it is done
    var hearing = false          // voice came in since the last text went out; the page shows typing dots meanwhile
    var tap: (([Float], Double) -> Void)?  // gets every converted 16 kHz piece with the wall time of its first sample (for the diarizer)
    var generation = 0           // bumped when the window is finalised, so a late pass does not trim the next window
    let lock = NSLock()

    init(_ src: String, _ rec: Recorder) { self.src = src; self.rec = rec }

    func feed(_ buf: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        if converter?.inputFormat != buf.format {
            converter = AVAudioConverter(from: buf.format, to: target)
            converter?.downmix = true
        }
        guard let conv = converter else { return }
        let cap = AVAudioFrameCount(Double(buf.frameLength) * 16000 / buf.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return }
        var given = false
        conv.convert(to: out, error: nil) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true; status.pointee = .haveData; return buf
        }
        let now = Date().timeIntervalSince1970, n = Int(out.frameLength)
        lastFeed = now
        if t0 == 0 { t0 = now - Double(n) / 16000 }
        // System audio stops delivering buffers while nothing plays: treat the gap as silence and resync the clock.
        if now - (t0 + Double(clock + pending.count + n) / 16000) > 0.3 {
            if !window.isEmpty { submitLocked(final: true) }
            pending = []
            clock = Int((now - t0) * 16000) - n
        }
        let piece = Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: n))
        tap?(piece, t0 + Double(clock + pending.count) / 16000)
        pending += piece
        var i = 0
        while pending.count - i >= frame {
            step(Array(pending[i..<i + frame])); i += frame
        }
        pending.removeFirst(i)
    }

    private func step(_ f: [Float]) {
        let rms = (f.reduce(0) { $0 + $1 * $1 } / Float(frame)).squareRoot()
        if window.isEmpty { windowStart = clock }
        window += f; sinceUpdate += frame; frames += 1; sumRms += rms; peak = max(peak, rms)
        quietRun = rms < max(0.002, 0.2 * sumRms / Float(frames)) ? quietRun + 1 : 0
        clock += frame
        if rms > voice && !hearing {
            hearing = true
            rec.hearing(src, true)
        }
        if window.count >= windowMax || (window.count >= commitAfter && quietRun >= commitPause) {
            submitLocked(final: true)
        } else if (sinceUpdate >= updateAfter && quietRun >= updatePause) || sinceUpdate >= updateMax {
            submitLocked(final: false)
        }
    }

    private func submitLocked(final: Bool) {
        sinceUpdate = 0
        if peak < silence {  // nothing but silence so far: start over without asking the model
            if final || window.count >= commitAfter { resetLocked() }
            if hearing { hearing = false; rec.hearing(src, false) }
            return
        }
        if !final && updating { return }
        let audio = window, src = src, w = windowMs, gen = generation
        if !final { updating = true }
        rec.asrQueue.async { [self] in
            guard let segs = rec.transcribe(audio) else { return }
            lock.lock()
            if !final && gen == generation {
                let now = sentences(segs)
                let n = lockableSentences(now, audioEnd: Double(audio.count) / 16000)
                if n > 0 {
                    // Lock the finished sentences as a final window of their own and cut their audio off; the rest carries on as a new window.
                    let last = now[n - 1], cut = min(Int((last.end + (last.next ?? last.end)) / 2 * 16000), window.count)
                    let shift = Double(cut) / 16000
                    window.removeFirst(cut)
                    windowStart += cut
                    rec.window(src, w, true, Array(segs[..<last.tokenEnd]))
                    rec.window(src, windowMs, false, segs[last.tokenEnd...].map { ($0.start - shift, $0.end - shift, $0.text) })
                } else {
                    rec.window(src, w, false, segs)
                }
            } else {
                rec.window(src, w, final, segs)
            }
            if !final { updating = false }
            let was = hearing
            hearing = false  // text is out; the next loud frame turns the dots back on
            lock.unlock()
            if was { rec.hearing(src, false) }
        }
        if final { resetLocked() }
    }

    /// Wall time of the window start: the key its lines are replaced by, so it must come out the same for every pass.
    private var windowMs: Int { Int((t0 + Double(windowStart) / 16000) * 1000) }

    private func resetLocked() { window = []; frames = 0; sumRms = 0; peak = 0; quietRun = 0; generation += 1 }

    func flush() { lock.lock(); if !window.isEmpty { submitLocked(final: true) }; lock.unlock() }

    /// Finalise the window when buffers stopped arriving.
    func flushIfIdle() {
        lock.lock(); defer { lock.unlock() }
        if !window.isEmpty && Date().timeIntervalSince1970 - lastFeed > 0.5 { submitLocked(final: true) }
    }
}

private final class SysOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    unowned let rec: Recorder
    init(_ rec: Recorder) { self.rec = rec }

    func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let fd = sb.formatDescription else { return }
        let fmt = AVAudioFormat(cmAudioFormatDescription: fd)
        let n = AVAudioFrameCount(sb.numSamples)
        guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n) else { return }
        buf.frameLength = n
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(n), into: buf.mutableAudioBufferList) == noErr else { return }
        rec.feedSystem(buf)
    }
}

// MARK: who else is using the microphone (Zoom, Chrome with Meet, Slack...)

private func prop<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ initial: T) -> T {
    var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var v = initial, size = UInt32(MemoryLayout<T>.size)
    AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &v)
    return v
}

/// Names of apps holding the microphone, except macOS itself (Siri, dictation, ScreenCaptureKit) and Waffle. FaceTime counts.
func callApps() -> [String] {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    let system = AudioObjectID(kAudioObjectSystemObject)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids)
    var names = Set<String>()
    for id in ids where prop(id, kAudioProcessPropertyIsRunningInput, UInt32(0)) != 0 {
        let pid: pid_t = prop(id, kAudioProcessPropertyPID, 0)
        let bundle = prop(id, kAudioProcessPropertyBundleID, "" as CFString) as String
        if pid == getpid() || (bundle.hasPrefix("com.apple.") && bundle != "com.apple.FaceTime") { continue }
        var buf = [CChar](repeating: 0, count: 256)
        proc_name(pid, &buf, 256)
        names.insert(NSRunningApplication(processIdentifier: pid)?.localizedName ?? (bundle.isEmpty ? String(cString: buf) : bundle))
    }
    return names.sorted()
}
