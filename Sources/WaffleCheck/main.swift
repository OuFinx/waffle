// End-to-end check with the real speech models, for CI on a Mac: `swift run -c release WaffleCheck`. Speech is made with macOS's own
// voices (`say`) in several languages and at slow, normal and fast rates, then recognized the way Waffle does it: a whole clip at once,
// live through the windows with voice detection (Engine + Windower, the code the app runs), and the pass after a call (a long
// recording, its tape, its speakers). Fails when the text is too far from what was said.
import AVFoundation
import FluidAudio
import Foundation

func say(_ voice: String, _ rate: Int, _ text: String) throws -> [Float] {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("waffle-check-\(UUID().uuidString).aiff")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    p.arguments = ["-v", voice, "-r", String(rate), "-o", url.path, text]
    try p.run(); p.waitUntilExit()
    guard p.terminationStatus == 0 else { throw NSError(domain: "say", code: Int(p.terminationStatus)) }
    defer { try? FileManager.default.removeItem(at: url) }
    return try AudioConverter().resampleAudioFile(url)
}

func voices() -> Set<String> {
    let p = Process(), pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    p.arguments = ["-v", "?"]
    p.standardOutput = pipe
    try? p.run(); p.waitUntilExit()
    let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    return Set(text.split(separator: "\n").compactMap { $0.split(separator: " ").first.map(String.init) })
}

/// Word error rate over lowercased words of letters and digits.
func wer(_ ref: String, _ hyp: String) -> Double {
    let r = words(ref), h = words(hyp)
    guard !r.isEmpty else { return h.isEmpty ? 0 : 1 }
    var d = Array(0...h.count)
    for i in 1...r.count {
        var prev = d[0]; d[0] = i
        for j in stride(from: 1, through: h.count, by: 1) {
            let cur = d[j]
            d[j] = min(d[j] + 1, d[j - 1] + 1, prev + (r[i - 1] == h[j - 1] ? 0 : 1))
            prev = cur
        }
    }
    return Double(d[h.count]) / Double(r.count)
}

func pad(_ x: [Float], _ seconds: Double) -> [Float] { quiet(Int(seconds * 16000)) + x + quiet(Int(seconds * 16000)) }

/// The live path: 256 ms at a time, voice detection, the windows, each pass recognized while the next audio comes in, the text as the
/// transcript keeps it. Returns the final text and the longest pass.
func live(_ audio: [Float]) async throws -> (text: String, longest: Int, passes: Int, firstText: Double?) {
    let w = Windower()
    var state: VadStreamState?, speaking = false, lines: [Line] = [], waiting: [Pass] = [], longest = 0, passes = 0, firstText: Double?
    func run(_ ps: [Pass], at t: Double) async throws {
        for p in ps {
            longest = max(longest, p.audio.count); passes += 1
            let tokens = try await Engine.shared.transcribe(p.audio)
            for e in w.done(p, tokens) {
                if firstText == nil, !e.segments.isEmpty { firstText = t }
                lines = replaceWindow(lines, src: "sys", w: e.start / 16, part: 1, final: e.final, segments: e.segments)
            }
        }
    }
    var i = 0
    while i + 4096 <= audio.count {
        let x = Array(audio[i..<i + 4096])
        try await run(waiting, at: Double(i) / 16000)
        let p: Float
        if let r = await Engine.shared.speech(x, state) { state = r.state; p = r.p } else { p = 0 }
        speaking = speaking ? p >= 0.35 : p >= 0.5
        waiting = w.push(x, speech: speaking)
        i += 4096
    }
    try await run(waiting, at: Double(i) / 16000)
    try await run(w.flush(), at: Double(i) / 16000)
    guard lines.allSatisfy(\.final) else { throw NSError(domain: "check", code: 1, userInfo: [NSLocalizedDescriptionKey: "lines left open"]) }
    return (lines.map(\.text).joined(separator: " "), longest, passes, firstText)
}

let samples: [(lang: String, voices: [String], text: String)] = [
    ("English", ["Samantha", "Alex", "Daniel"], "Good morning everyone. Let us start with the release plan. The database migration is blocked, so Oleg will rotate the credentials by Thursday. Any questions? No? Great, then we move on to hiring."),
    ("Ukrainian", ["Lesya"], "Доброго ранку всім. Почнімо з плану релізу. Міграція бази даних заблокована, тому Олег оновить облікові дані до четверга. Є питання? Немає? Чудово, тоді переходимо до найму."),
    ("Russian", ["Milena", "Yuri"], "Доброе утро всем. Давайте начнём с плана релиза. Миграция базы данных заблокирована, поэтому Олег обновит учётные данные до четверга. Есть вопросы? Нет? Отлично, тогда переходим к найму."),
    ("Polish", ["Zosia"], "Dzień dobry wszystkim. Zacznijmy od planu wydania. Migracja bazy danych jest zablokowana, więc Oleg zmieni dane dostępowe do czwartku. Są pytania? Nie? Świetnie, przechodzimy do rekrutacji."),
    ("German", ["Anna"], "Guten Morgen zusammen. Fangen wir mit dem Release Plan an. Die Datenbankmigration ist blockiert, deshalb erneuert Oleg die Zugangsdaten bis Donnerstag. Gibt es Fragen? Nein? Super, dann weiter zur Einstellung."),
]

var failures: [String] = []
func check(_ ok: Bool, _ what: String) { print(ok ? "  ok   " : "  FAIL ", what); if !ok { failures.append(what) } }

let started = Date()
print("downloading and loading the models...")
_ = try await AsrModels.download(version: Engine.asrVersion)
_ = try await VadManager(config: .default)
Engine.shared.retain()
_ = try await Engine.shared.transcribe(quiet(16000))
print(String(format: "models ready in %.0f s", Date().timeIntervalSince(started)))

let have = voices()
var longStream: [Float] = [], longText: [String] = [], longVoices: [(from: Int, to: Int, voice: String)] = []
for s in samples {
    guard let voice = s.voices.first(where: have.contains) else { print("\(s.lang): no voice installed, skipped"); continue }
    for rate in [150, 200, 280] {
        let clip = try say(voice, rate, s.text)
        let t0 = Date()
        let whole = try await Engine.shared.transcribe(clip).map(\.text).joined()
        let took = Date().timeIntervalSince(t0)
        let lv = try await live(pad(clip, 1))
        let a = wer(s.text, whole), b = wer(s.text, lv.text)
        print(String(format: "\(s.lang) \(voice) \(rate) wpm (%.1f s): whole %.0f%% in %.2f s, live %.0f%% (%d passes, longest %.1f s, first text at %.1f s)",
                     Double(clip.count) / 16000, a * 100, took, b * 100, lv.passes, Double(lv.longest) / 16000, lv.firstText ?? -1))
        print("    whole: \(whole.trimmingCharacters(in: .whitespaces))")
        print("    live:  \(lv.text)")
        check(a <= 0.2, "\(s.lang) \(rate) wpm whole clip under 20% WER")
        check(b <= a + 0.1, "\(s.lang) \(rate) wpm live within 10 points of the whole clip")
        check(lv.longest <= 240_000, "\(s.lang) \(rate) wpm no pass longer than 15 s")
        if rate == 200 {
            longVoices.append((longStream.count, longStream.count + clip.count, voice))
            longStream += clip + quiet(16000)
            longText.append(s.text)
        }
    }
}

// The pass after a call: a long recording (several voices), through the tape (speech only, timed on the wall clock), recognized at once.
if longStream.count > 16000 * 20 {
    var tape = Tape(), state: VadStreamState?, speaking = false
    var i = 0
    while i + 4096 <= longStream.count {
        let x = Array(longStream[i..<i + 4096])
        if let r = await Engine.shared.speech(x, state) { state = r.state; speaking = speaking ? r.p >= 0.35 : r.p >= 0.5 }
        tape.add(x, ms: 1_000_000 + Double(i) / 16, speech: speaking)
        i += 4096
    }
    let t0 = Date()
    let tokens = try await Engine.shared.transcribe(tape.floats)
    let lines = tapeLines(tokens, src: "sys", part: 1, clock: tape.clock)
    let text = lines.map(\.text).joined(separator: " ")
    let e = wer(longText.joined(separator: " "), text)
    print(String(format: "second pass: %.0f s of meeting, tape %.0f s, %.0f%% WER in %.1f s, %d lines", Double(longStream.count) / 16000, tape.seconds, e * 100, Date().timeIntervalSince(t0), lines.count))
    check(e <= 0.2, "second pass under 20% WER")
    check(lines.allSatisfy { $0.t >= 1_000_000 && $0.t <= 1_000_000 + longStream.count / 16 }, "second pass lines on the wall clock")
    // every line starts inside the clip it came from
    let placed = lines.filter { l in longVoices.contains { Double(l.t - 1_000_000) >= Double($0.from) / 16 - 600 && Double(l.t - 1_000_000) <= Double($0.to) / 16 } }
    check(placed.count == lines.count, "second pass lines timed inside their clip (\(placed.count) of \(lines.count))")
    let t1 = Date()
    let turns = try await Engine.shared.diarize(longStream, maxSpeakers: nil)
    let speakers = Set(turns.map(\.spk))
    print(String(format: "speakers: %d found for %d voices in %.1f s", speakers.count, Set(longVoices.map(\.voice)).count, Date().timeIntervalSince(t1)))
    check(speakers.count >= 2, "speakers told apart after the call")
}

Engine.shared.release()
print(failures.isEmpty ? "all checks passed" : "\(failures.count) checks failed")
exit(failures.isEmpty ? 0 : 1)
