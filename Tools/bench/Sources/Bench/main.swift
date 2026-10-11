// A meeting recording (16 kHz wav) as the "Them" stream through the app's own code: Logic.swift and Engine.swift are the app's files
// (symlinks); what Recorder.swift's Source and Model.polish do around them is re-created here with the same constants. Change this file
// along with Source or polish. `Bench <wav> <out.json>` writes the lines with their live and after-the-call voices; `Bench <wav> <out.json>
// whole` recognizes the whole file at once instead (the model's own level, for comparison).
import FluidAudio
import Foundation

let path = CommandLine.arguments[1], out = CommandLine.arguments[2]
let audio = try AudioConverter().resampleAudioFile(URL(fileURLWithPath: path))
let base = 1_700_000_000_000.0
func ms(_ s: Int) -> Double { base + Double(s) / 16 }
func write(_ info: [String: Any]) throws { try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted]).write(to: URL(fileURLWithPath: out)) }

_ = try await AsrModels.download(version: Engine.asrVersion)
_ = try await VadManager(config: .default)
Engine.shared.retain()
_ = try await Engine.shared.transcribe(quiet(16000))
if CommandLine.arguments.count > 3 {
    let t0 = Date()
    let t = try await Engine.shared.transcribe(audio).map(\.text).joined()
    try write(["audio": Double(audio.count) / 16000, "liveTime": Date().timeIntervalSince(t0), "lines": [["t": 0.0, "text": t, "live": "", "polish": ""]]])
    exit(0)
}

// Source: voice detection, the windows and their passes, the tape, live speaker labels
let w = Windower()
var vad: VadStreamState?, speaking = false, level = VoiceLevel(most: 20), tape = Tape(), lines: [Line] = [], turns: [Turn] = []
var asrTime = 0.0, vadTime = 0.0, diarTime = 0.0, passes = 0, thinRetries = 0, frames = 0
let diarizer = Nemotron3Diarizer(config: .fast32, models: try await Nemotron3Models.loadFromHuggingFace(config: .fast32))
var diarPending: [Float] = [], probs: [Float] = [], nspk = 0, windows: [Int: [Segment]] = [:]  // raw diarizer output and each window's last words, for replaying labels offline

func emit(_ chunks: [Nemotron3ChunkResult]) {
    for c in chunks {
        let at = Double(frames) / 100
        probs += c.probabilities.prefix(c.frameCount * c.numSpeakers); nspk = c.numSpeakers
        for s in Nemotron3Diarizer.segments(probabilities: c.probabilities, frameCount: c.frameCount, numSpeakers: c.numSpeakers) {
            turns.append(Turn(start: Int(ms(Int((at + Double(s.startSeconds)) * 16000))), end: Int(ms(Int((at + Double(s.endSeconds)) * 16000))), spk: "1-\(s.speakerIndex + 1)"))
        }
        frames += c.frameCount
    }
}
func run(_ ps: [Pass]) async throws {
    for p in ps {
        let t0 = Date()
        var pass = p, tokens = try await Engine.shared.transcribe(p.audio)
        if w.thin(p, tokens) {
            let bare = try await Engine.shared.transcribe(p.bare.audio)
            if w.words(p.bare, bare) > Int(Double(w.words(p, tokens)) * 1.3) { pass = p.bare; tokens = bare; w.forgetContext(p); thinRetries += 1 }
        }
        asrTime += Date().timeIntervalSince(t0); passes += 1
        for e in w.done(pass, tokens) { windows[Int(ms(e.start))] = e.segments; lines = replaceWindow(lines, src: "sys", w: Int(ms(e.start)), part: 1, final: e.final, segments: e.segments) }
    }
}
let started = Date()
var waiting: [Pass] = [], i = 0
while i + 4096 <= audio.count {
    let x = Array(audio[i..<i + 4096])
    try await run(waiting)  // the passes run one chunk late, as they do while audio keeps coming
    let t0 = Date()
    var p: Float = 0
    if let r = await Engine.shared.speech(level.adjust(x).heard, vad) { vad = r.state; p = r.p }
    vadTime += Date().timeIntervalSince(t0)
    speaking = speaking ? p >= 0.35 : p >= 0.5
    tape.add(x, ms: ms(i), speech: speaking)
    let t1 = Date()
    diarPending += x.map { $0 + Float.random(in: -0.0001...0.0001) }
    if diarPending.count >= 8000 {
        let a = diarPending
        diarPending = []
        emit(try await Engine.shared.exclusive { () throws -> [Nemotron3ChunkResult] in diarizer.appendAudio(a); return try diarizer.processBufferedAudio() })
    }
    diarTime += Date().timeIntervalSince(t1)
    waiting = w.push(x, speech: speaking)
    i += 4096
}
try await run(waiting)
try await run(w.flush())
emit(try await Engine.shared.exclusive { () throws -> [Nemotron3ChunkResult] in diarizer.appendAudio(diarPending); return try diarizer.finishStream() })
let liveTime = Date().timeIntervalSince(started)
lines = lines.map { var l = $0; l.final = true; return l }
lines = splitAtVoices(lines, turns)
let live = labelSpeakers(lines, turns)  // Model.labelled, no call window

// Model.polish, no calendar and no call window
let t2 = Date()
let segs = try await Engine.shared.diarize(tape.floats, maxSpeakers: nil)
let offTurns = segs.map { Turn(start: Int(tape.clock.ms(Int($0.start * 16000))), end: Int(tape.clock.ms(Int($0.end * 16000))), spk: $0.spk) }
let use = !offTurns.isEmpty && live.contains { $0.spk == nil }
var polished = live
if use {
    let carried = carryVoices(live: live, turns: offTurns)
    polished = labelSpeakers(live, offTurns.map { Turn(start: $0.start, end: $0.end, spk: carried[$0.spk] ?? "1-\($0.spk)") })
    polished = zip(live, polished).map { $0.spk == nil ? $1 : $0 }
}
let polishTime = Date().timeIntervalSince(t2)

try write(["audio": Double(audio.count) / 16000, "liveTime": liveTime, "asrTime": asrTime, "vadTime": vadTime, "diarTime": diarTime, "passes": passes, "thinRetries": thinRetries,
           "tape": tape.seconds, "liveVoices": Set(live.compactMap(\.spk)).count, "offVoices": Set(offTurns.map(\.spk)).count, "polishUsed": use, "polishTime": polishTime,
           "lines": zip(live, polished).map { a, b in ["t": (Double(a.t) - base) / 1000, "w": (Double(a.w ?? 0) - base) / 1000, "text": a.text, "live": a.spk ?? "", "polish": b.spk ?? ""] as [String: Any] },
           "turns": turns.map { [(Double($0.start) - base) / 1000, (Double($0.end) - base) / 1000, $0.spk] as [Any] }, "nspk": nspk, "probs": probs.map { (Double($0) * 100).rounded() / 100 },
           "windows": windows.sorted { $0.key < $1.key }.map { ["w": (Double($0.key) - base) / 1000, "tokens": $0.value.map { [$0.start, $0.end, $0.text] as [Any] }] as [String: Any] }])
print(String(format: "done in %.0f s", liveTime))
