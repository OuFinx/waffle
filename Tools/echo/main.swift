// Echo bench: `swift run -c release WaffleBench <set dir> <cache dir>`. How the mic path handles the call's sound coming back into the mic when the user is on speakers, and what each way of handling it costs.
// The system stream is a stretch of a real meeting (16 kHz wav, <name>.ref.json word times, <name>.off offset). The mic stream is the user's own speech (macOS voices) plus the system stream played through a room: a delay of 10-200 ms, a gain of -30 to -6 dB, a low-pass, a little reverb, noise. Some of the user's lines repeat the other side's last words, and in the "overtalk" layout the user talks over them.
// Both streams go through the app's own code (Logic.swift, Engine.swift): the echo check per 256 ms (echoLike), voice detection, the windows and the recognizer, then replaceWindow with dropEcho.
// Voice processing can not run on a file. The "raw" rooms are the mic without it (it fails for some device pairs); the "vp" rooms model what it leaves: the echo 25 dB further down, only 10 dB down for 200 ms after a sound starts (it adapts) and 15 dB down while the user talks (double talk). That residual model is a guess, not a measurement.
// Recognition results are cached per run in <cache dir>; a run that is cached does not load the models, so the strategies after recognition can be changed and scored again quickly.
import FluidAudio
import Foundation

let setDir = CommandLine.arguments[1], cacheDir = CommandLine.arguments[2]
try FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)

struct Rng { var s: UInt64; mutating func next() -> Double { s &+= 0x9E3779B97F4A7C15; var z = s; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53) } }

func say(_ voice: String, _ text: String) throws -> [Float] {
    let url = URL(fileURLWithPath: cacheDir).appendingPathComponent("say-\(voice)-\(String(text.map { $0.isLetter ? $0 : "_" }.prefix(60)))-\(text.count).aiff")
    if !FileManager.default.fileExists(atPath: url.path) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-v", voice, "-r", "185", "-o", url.path, text]
        try p.run(); p.waitUntilExit()
    }
    return try AudioConverter().resampleAudioFile(url)
}
func scaled(_ x: [Float], to level: Float) -> [Float] { let l = speechLevel(x); return l > 0 ? x.map { $0 * level / l } : x }

let mine = ["I think we should move the deadline to the end of the month.", "Can you send me the slides after the meeting?",
            "That sounds good to me, let's go with the second option.", "I'm not sure the budget covers the extra hardware.",
            "We tried that last year and it did not work very well.", "Let me check with the design team and get back to you.",
            "Could you explain the numbers on the last chart again?", "I agree, but we need a fallback plan just in case.",
            "My main worry is the testing time before the release.", "Who is going to own the documentation for this?",
            "Sorry, I missed that, could you repeat the last part?", "We should write this down so nobody forgets it.",
            "The customer asked for a demo next Tuesday afternoon.", "I can take that one, it should not take long.",
            "Maybe we can split the work between the two groups.", "Honestly the old version was faster for most people.",
            "Let's keep the meeting short today, I have another call.", "Has anyone looked at the error reports from yesterday?"]

// MARK: the meeting, the rooms, the mic

struct Utt { let a: Int; let b: Int; let words: [String]; let repeats: Bool }  // ms on the stream clock
struct Scene { let sys: [Float]; let user: [Float]; let utts: [Utt] }

/// Words of the other side with times in seconds, from the set's reference (punctuation and fillers left out).
func refWords(_ name: String) throws -> [(Double, Double, String)] {
    let off = Double(try String(contentsOfFile: "\(setDir)/\(name).off", encoding: .utf8).split(separator: " ")[0])!
    let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "\(setDir)/\(name).ref.json"))) as! [[Any]]
    let fill: Set<String> = ["uh", "um", "mm", "hmm", "huh", "ah", "oh", "eh", "hm"]
    return raw.compactMap { r in
        let w = (r[3] as! String).lowercased().filter { $0.isLetter || $0 == "'" }
        return w.isEmpty || fill.contains(w) ? nil : ((r[0] as! Double) - off, (r[1] as! Double) - off, w)
    }
}

/// "turns": the other side in stretches of 6-10 s, the user answering in the gaps (every third answer repeats their last words, some starting before they finish). "overtalk": the other side without gaps, the user talking over them every 9 s.
func scene(_ name: String, overtalk: Bool, voice: String, seconds: Double = 150) throws -> Scene {
    let audio = try AudioConverter().resampleAudioFile(URL(fileURLWithPath: "\(setDir)/\(name).wav"))
    let from = 30.0, to = from + seconds
    let ws = try refWords(name).filter { $0.0 >= from && $0.1 <= to }
    let full = scaled(Array(audio[Int(from * 16000)..<Int(to * 16000)]), to: 0.1)
    func sysAt(_ a: Double, _ b: Double) -> [Float] { Array(full[max(0, Int((a - from) * 16000))..<min(full.count, Int((b - from) * 16000))]) }
    func repeated(_ before: Double) -> String? {
        let last = ws.filter { $0.1 <= before && $0.0 >= before - 4 }.suffix(5).map(\.2)
        return last.count >= 3 ? last.joined(separator: " ") : nil
    }
    var sys: [Float] = [], user: [Float] = [], utts: [Utt] = [], k = 0
    func speak(_ text: String, at: Int, repeats: Bool) throws {
        let x = scaled(try say(voice, text), to: 0.1)
        if user.count < at + x.count { user += [Float](repeating: 0, count: at + x.count - user.count) }
        for (i, v) in x.enumerated() { user[at + i] += v }
        utts.append(Utt(a: at / 16, b: (at + x.count) / 16, words: words(text), repeats: repeats))
    }
    if overtalk {
        sys = full
        var t = 3.0
        while t < seconds - 6 {
            if k % 3 == 2, let r = repeated(from + t) { try speak(r, at: Int(t * 16000), repeats: true) } else { try speak(mine[k % mine.count], at: Int(t * 16000), repeats: false) }
            k += 1; t += 9
        }
    } else {
        var a = from
        while a < to - 10 {
            // a stretch ends at a pause between words, 6 to 10 s in
            let ends = ws.filter { $0.1 > a + 6 && $0.1 < a + 10 }
            let b = ends.enumerated().first { i, w in i + 1 < ends.count && ends[i + 1].0 - w.1 >= 0.15 }?.element.1 ?? ends.last?.1 ?? a + 8
            let s = sysAt(a, b + 0.1)
            sys += s
            if k % 3 == 2, let r = repeated(b + 0.1) {
                let at = k % 2 == 0 ? sys.count + 4800 : sys.count - 9600  // 0.3 s after they stop, or 0.6 s before
                try speak(r, at: at, repeats: true)
            } else {
                try speak(mine[k % mine.count], at: sys.count + 4800, repeats: false)
            }
            sys += [Float](repeating: 0, count: user.count + 11200 - sys.count)
            k += 1; a = b + 0.1
        }
    }
    let n = max(sys.count, user.count) + 32000
    return Scene(sys: sys + [Float](repeating: 0, count: n - sys.count), user: user + [Float](repeating: 0, count: n - user.count), utts: utts)
}

struct Room { let delayMs: Double; let gainDb: Float; let cutoff: Float; let vp: Bool }

/// The system stream as the mic hears it from the speakers.
func echo(_ sys: [Float], _ room: Room, user: [Float], seed: UInt64) -> [Float] {
    var rng = Rng(s: seed)
    let d = Int(room.delayMs * 16), a = Float(exp(-2 * Double.pi * Double(room.cutoff) / 16000))
    var taps: [(Int, Float)] = [(0, 1)]
    for _ in 0..<12 { let t = 5 + rng.next() * 115; taps.append((Int(t * 16), Float(0.6 * exp(-t / 40) * (rng.next() < 0.5 ? -1 : 1)))) }
    var y = [Float](repeating: 0, count: sys.count), lp: Float = 0
    let g = pow(10, room.gainDb / 20)
    for i in 0..<sys.count {
        var v: Float = 0
        for (t, k) in taps where i - d - t >= 0 { v += k * sys[i - d - t] }
        lp = (1 - a) * v + a * lp
        y[i] = g * lp
    }
    guard room.vp else { return y }
    // what voice processing leaves, per 20 ms, ramped between frames
    let f = 320, frames = y.count / f
    func rms(_ x: [Float], _ k: Int) -> Float { var e: Float = 0; for i in k * f..<(k + 1) * f { e += x[i] * x[i] }; return (e / Float(f)).squareRoot() }
    var gains = [Float](repeating: 0, count: frames + 1), avg: Float = 0, onset = 0
    for k in 0..<frames {
        let r = rms(y, k)
        if r > 3 * avg + 0.0005 { onset = 10 }
        avg = 0.9 * avg + 0.1 * r
        let db: Float = onset > 0 ? -10 : rms(user, k) > 0.005 ? -15 : -25
        onset -= 1
        gains[k] = pow(10, (db + Float(rng.next() * 8 - 4)) / 20)
    }
    gains[frames] = gains[max(0, frames - 1)]
    for i in 0..<frames * f { let k = i / f, w = Float(i % f) / Float(f); y[i] *= gains[k] * (1 - w) + gains[k + 1] * w }
    return y
}

func noise(_ n: Int, seed: UInt64) -> [Float] { var r = Rng(s: seed); return (0..<n).map { _ in Float(r.next() + r.next() + r.next() - 1.5) * 0.0008 } }

// MARK: the app's path, live, 256 ms at a time

nonisolated(unsafe) var loaded = false
struct Ev: Codable { let w: Int; let final: Bool; let segs: [[String]] }

/// One stream through voice detection, the windows and the recognizer, as Source.process and Source.run do. `gate` says a piece is echo (it is then replaced by room noise, as the app does).
func live(_ audio: [Float], mic: Bool, key: String, gate: (([Float], Int) -> Bool)? = nil) async throws -> [Ev] {
    let path = "\(cacheDir)/\(key).json"
    if let d = FileManager.default.contents(atPath: path) { return try JSONDecoder().decode([Ev].self, from: d) }
    if !loaded {  // the models load only when a run is not cached, so scoring again needs no lock
        _ = try await AsrModels.download(version: Engine.asrVersion)
        _ = try await VadManager(config: .default)
        Engine.shared.retain()
        _ = try await Engine.shared.transcribe(quiet(16000))
        loaded = true
    }
    let w = Windower()
    var vad: VadStreamState?, speaking = false, level = VoiceLevel(most: mic ? 8 : 20), out: [Ev] = [], waiting: [Pass] = []
    func run(_ ps: [Pass]) async throws {
        for p in ps {
            var p = p, tokens = try await Engine.shared.transcribe(p.audio)
            if w.thin(p, tokens) {
                let bare = try await Engine.shared.transcribe(p.bare.audio)
                if w.words(p.bare, bare) > Int(Double(w.words(p, tokens)) * 1.3) { w.forgetContext(p); p = p.bare; tokens = bare }
            }
            for e in w.done(p, tokens) { out.append(Ev(w: e.start / 16, final: e.final, segs: e.segments.map { [String($0.start), String($0.end), $0.text] })) }
        }
    }
    var i = 0
    while i + 4096 <= audio.count {
        var x = Array(audio[i..<i + 4096])
        try await run(waiting)
        if let gate, gate(x, i) { x = quiet(4096) }
        let (heard, _) = level.adjust(x)
        var p: Float = 0
        if let r = await Engine.shared.speech(heard, vad) { vad = r.state; p = r.p }
        speaking = speaking ? p >= 0.35 : p >= 0.5
        waiting = w.push(x, speech: speaking)
        i += 4096
    }
    try await run(waiting)
    try await run(w.flush())
    try JSONEncoder().encode(out).write(to: URL(fileURLWithPath: path))
    return out
}

func lines(_ sys: [Ev], _ mic: [Ev], heard: @escaping (Int, Int) -> Bool) -> [Line] {
    var ls: [Line] = []
    for (src, evs) in [("sys", sys), ("mic", mic)] {
        for e in evs { ls = replaceWindow(ls, src: src, w: e.w, part: 1, final: e.final, segments: e.segs.map { (Double($0[0])!, Double($0[1])!, $0[2]) }, heard: heard) }
    }
    return ls
}

/// The user's words found in "Me" per line of theirs (a "Me" line counts for the user line it starts in, from 1.5 s before), and the other "Me" words: echo (or, in the clean run, made-up words).
func score(_ ls: [Line], _ utts: [Utt]) -> (kept: [Int], extra: Int) {
    var got = [[String: Int]](repeating: [:], count: utts.count), kept = [Int](repeating: 0, count: utts.count), extra = 0
    for (i, u) in utts.enumerated() { for w in u.words { got[i][w, default: 0] += 1 } }
    for l in ls where l.src == "mic" {
        let ws = words(l.text)
        guard let i = utts.firstIndex(where: { l.t >= $0.a - 1500 && l.t <= $0.b }) else { extra += ws.count; continue }
        for w in ws { if let c = got[i][w], c > 0 { got[i][w] = c - 1; kept[i] += 1 } else { extra += 1 } }
    }
    return (kept, extra)
}

// MARK: audio evidence for the text filter, over a whole "Me" line, from 8 ms loudness (the app uses Logic.followsLoudness; the others are what it was picked against)

func env(_ x: [Float]) -> [Float] { stride(from: 0, to: x.count - 127, by: 128).map { k in (x[k..<k + 128].reduce(0) { $0 + $1 * $1 } / 128).squareRoot() } }
func pearson(_ a: ArraySlice<Float>, _ b: ArraySlice<Float>) -> Float {
    let n = Float(a.count), ma = a.reduce(0, +) / n, mb = b.reduce(0, +) / n
    var sab: Float = 0, saa: Float = 0, sbb: Float = 0
    for (x, y) in zip(a, b) { sab += (x - ma) * (y - mb); saa += (x - ma) * (x - ma); sbb += (y - mb) * (y - mb) }
    return saa > 0 && sbb > 0 ? sab / (saa * sbb).squareRoot() : 0
}
/// Best correlation of the mic's loudness with the system's, the system 0-300 ms earlier.
func envCorr(_ m: [Float], _ s: [Float], _ from: Int, _ to: Int) -> Float {
    let a = max(38, from / 8), b = min(m.count, to / 8)
    guard b - a >= 10 else { return 0 }
    return (0...38).map { lag in pearson(m[a..<b], s[(a - lag)..<(b - lag)]) }.max()!
}
/// Share of the mic's loudness the system's explains at its best delay, with the gain read low (the user's voice only pushes it up).
func residual(_ m: [Float], _ s: [Float], _ from: Int, _ to: Int) -> Float {
    let a = max(38, from / 8), b = min(m.count, to / 8)
    guard b - a >= 10 else { return 1 }
    let lag = (0...38).max { pearson(m[a..<b], s[(a - $0)..<(b - $0)]) < pearson(m[a..<b], s[(a - $1)..<(b - $1)]) }!
    let peak = s[(a - lag)..<(b - lag)].max()!
    let ratios = (a..<b).filter { s[$0 - lag] > 0.2 * peak && peak > 0.003 }.map { m[$0] / s[$0 - lag] }.sorted()
    guard ratios.count >= 5 else { return 1 }
    let g = ratios[ratios.count / 5]
    var all: Float = 0, left: Float = 0
    for k in a..<b { all += m[k]; left += max(0, m[k] - g * s[k - lag]) }
    return all > 0 ? left / all : 1
}

// MARK: run

let names = ["Bmr006", "Bed002", "Bro018", "ES2004a"]
let rooms: [(String, Room)] = [(-6, 120.0, 4500), (-12, 30.0, 3500), (-20, 200.0, 3000), (-30, 60.0, 5000)].flatMap { g, d, c in
    [("raw", Room(delayMs: d, gainDb: Float(g), cutoff: Float(c), vp: false)), ("vp", Room(delayMs: d, gainDb: Float(g), cutoff: Float(c), vp: true))]
}


typealias Strategy = (name: String, gate: Bool, heard: ([Float], [Float]) -> (Int, Int) -> Bool)
let never: ([Float], [Float]) -> (Int, Int) -> Bool = { _, _ in { _, _ in false } }, always: ([Float], [Float]) -> (Int, Int) -> Bool = { _, _ in { _, _ in true } }
var strategies: [Strategy] = [("nothing", false, never), ("audio gate only", true, never), ("text filter only", false, always), ("now: gate + text", true, always)]
for t: Float in [0.2, 0.3, 0.4, 0.5] { strategies.append(("gate + text if loudness follows >= \(t)", true, { m, s in let me = env(m), th = env(s); return { envCorr(me, th, $0, $1) >= t } })) }
func loudness(_ x: [Float]) -> Loudness { var l = Loudness(); for k in stride(from: 0, to: x.count - 4095, by: 4096) { l.add(Array(x[k..<k + 4096]), ms: Double(k) / 16) }; return l }
strategies.append(("app: gate + text if followsLoudness", true, { m, s in let lm = loudness(m), ls = loudness(s); return { followsLoudness(mic: lm, sys: ls, from: $0, to: $1) } }))
for t: Float in [0.2, 0.35, 0.5] { strategies.append(("gate + text if residual <= \(t)", true, { m, s in let me = env(m), th = env(s); return { residual(me, th, $0, $1) <= t } })) }

// per strategy, per group ("raw turns" ...): own words lost, of them in repeats, repeat lines lost, echo words in Me
var table: [String: [String: (lost: Int, lostRep: Int, repLines: Int, echo: Int, words: Int, reps: Int)]] = [:]
for (mi, name) in names.enumerated() {
    for overtalk in [false, true] {
        let layout = overtalk ? "overtalk" : "turns"
        let sc = try scene(name, overtalk: overtalk, voice: ["Samantha", "Daniel"][mi % 2])
        let key = "\(name)-\(layout)"
        let sysEv = try await live(sc.sys, mic: false, key: "\(key)-sys")
        let clean = zip(sc.user, noise(sc.user.count, seed: 1)).map { $0 + $1 }
        let cleanEv = try await live(clean, mic: true, key: "\(key)-clean")
        let base = score(lines(sysEv, cleanEv, heard: { _, _ in false }), sc.utts)
        for (rname, room) in rooms.filter({ $0.1.gainDb == [-6, -12, -20, -30][mi] }) {
            let e = echo(sc.sys, room, user: sc.user, seed: UInt64(mi + 7))
            let micA = zip(zip(sc.user, e).map { $0 + $1 }, noise(sc.user.count, seed: 2)).map { $0 + $1 }
            let gate: ([Float], Int) -> Bool = { x, i in
                let lo = i - 4800, ref = (lo..<(i + 4096)).map { $0 >= 0 ? sc.sys[$0] : 0 }
                return echoLike(x, ref, maxLag: 4800)
            }
            let tag = "\(key)-\(rname)\(Int(room.gainDb))"
            let noneEv = try await live(micA, mic: true, key: "\(tag)-none")
            let gateEv = try await live(micA, mic: true, key: "\(tag)-gate", gate: gate)
            let group = "\(rname) \(layout)"
            for s in strategies {
                let r = score(lines(sysEv, s.gate ? gateEv : noneEv, heard: s.heard(micA, sc.sys)), sc.utts)
                var c = table[s.name, default: [:]][group] ?? (0, 0, 0, 0, 0, 0)
                for (i, u) in sc.utts.enumerated() {
                    let lost = max(0, base.kept[i] - r.kept[i])
                    c.lost += lost; c.words += base.kept[i]
                    if u.repeats { c.lostRep += lost; c.reps += 1; if base.kept[i] > 0 && r.kept[i] * 2 < base.kept[i] { c.repLines += 1 } }
                }
                c.echo += max(0, r.extra - base.extra)
                table[s.name, default: [:]][group] = c
            }
            print("\(tag): \(Int(room.delayMs)) ms, \(Int(room.gainDb)) dB")
        }
    }
}

let groups = ["raw turns", "raw overtalk", "vp turns", "vp overtalk"]
print("\nown words lost (of words the clean mic got) / repeat lines lost / echo words in Me")
print("strategy".padding(toLength: 44, withPad: " ", startingAt: 0) + groups.map { $0.padding(toLength: 26, withPad: " ", startingAt: 0) }.joined())
for s in strategies {
    let row = groups.map { g -> String in
        let c = table[s.name]![g]!
        return "\(c.lost)/\(c.words) \(c.repLines)/\(c.reps) \(c.echo)".padding(toLength: 26, withPad: " ", startingAt: 0)
    }
    print(s.name.padding(toLength: 44, withPad: " ", startingAt: 0) + row.joined())
}
