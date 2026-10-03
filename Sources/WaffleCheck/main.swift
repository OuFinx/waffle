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
func live(_ audio: [Float], trace: Bool = false) async throws -> (text: String, longest: Int, passes: Int, firstText: Double?) {
    let w = Windower()
    var state: VadStreamState?, speaking = false, lines: [Line] = [], waiting: [Pass] = [], longest = 0, passes = 0, firstText: Double?
    var level = VoiceLevel()
    func run(_ ps: [Pass], at t: Double) async throws {
        for p in ps {
            longest = max(longest, p.audio.count); passes += 1
            let tokens = try await Engine.shared.transcribe(p.audio)
            if trace { print(String(format: "      pass at %.1f s: %.1f s (%.1f context)%@: %@", t, Double(p.audio.count) / 16000, Double(p.ctx) / 16000, p.final ? " final" : "", tokens.map(\.text).joined())) }
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
        if let r = await Engine.shared.speech(level.adjust(x).heard, state) { state = r.state; p = r.p } else { p = 0 }
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
print("downloading and loading the models (Parakeet \(Engine.asrVersion == .v3 ? "v3" : "v3 ultra"))...")
_ = try await AsrModels.download(version: Engine.asrVersion)
_ = try await VadManager(config: .default)
Engine.shared.retain()
_ = try await Engine.shared.transcribe(quiet(16000))
print(String(format: "models ready in %.0f s", Date().timeIntervalSince(started)))

let have = voices()

// A quiet speaker (-40 dB, a far-off mic) right after a loud one: still heard, live and whole.
if have.contains("Samantha") {
    let loud = try say("Samantha", 200, "Let us start with the release plan for next week.")
    let soft = try say("Samantha", 200, "The database migration is blocked until Thursday.").map { $0 * 0.01 }
    let lv = try await live(pad(loud + quiet(3000) + soft, 1))
    let e = wer("Let us start with the release plan for next week. The database migration is blocked until Thursday.", lv.text)
    print(String(format: "quiet after loud, live: %.0f%%: %@", e * 100, lv.text))
    check(e <= 0.2, "a quiet speaker after a loud one is transcribed")
}
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
        if rate <= 200 { check(a <= 0.2, "\(s.lang) \(rate) wpm whole clip under 20% WER") }  // 280 wpm is past what the model hears well
        check(b <= a + 0.1, "\(s.lang) \(rate) wpm live within 10 points of the whole clip")
        check(lv.longest <= 240_000, "\(s.lang) \(rate) wpm no pass longer than 15 s")
    }
}

/// Who speaks when in a dialogue of two voices: each line said by the voice that says it.
func dialogue(_ a: String, _ b: String, _ lines: [String]) throws -> (audio: [Float], who: [(from: Int, to: Int, voice: Int)]) {
    var audio = quiet(16000), who: [(from: Int, to: Int, voice: Int)] = []
    for (i, l) in lines.enumerated() {
        let x = try say(i % 2 == 0 ? a : b, 190, l)
        who.append((audio.count, audio.count + x.count, i % 2)); audio += x + quiet(Int.random(in: 6000...14000))
    }
    return (audio, who)
}

/// Share of speech time whose voice label matches the true voice, under the best one-to-one mapping of two labels.
func purity(_ turns: [(start: Double, end: Double, spk: String)], _ who: [(from: Int, to: Int, voice: Int)]) -> Double {
    var overlap: [String: [Double]] = [:]
    for t in turns { for w in who {
        let o = min(t.end, Double(w.to) / 16000) - max(t.start, Double(w.from) / 16000)
        if o > 0 { overlap[t.spk, default: [0, 0]][w.voice] += o }
    } }
    let total = who.map { Double($0.to - $0.from) / 16000 }.reduce(0, +)
    let byLabel = overlap.values.map { max($0[0], $0[1]) }.reduce(0, +)  // each label counted as its best voice
    let voices = Set(overlap.values.map { $0[0] >= $0[1] ? 0 : 1 })
    return voices.count < 2 ? 0.5 * byLabel / total : byLabel / total
}

let pairs: [(String, String, [String])] = [
    ("Samantha", "Daniel", ["Hi Daniel, thanks for joining the call today.", "Hi, no problem, happy to help with the release.", "Where are we with the database migration?",
                            "It is blocked on credentials, I will rotate them tomorrow.", "Great. Can you also update the runbook?", "Sure, I will do that by Friday.",
                            "Perfect. Anything else we should discuss?", "No, I think that is all for today."]),
    ("Milena", "Yuri", ["Привет, Юрий, спасибо, что присоединился.", "Привет, без проблем, рад помочь с релизом.", "Как дела с миграцией базы данных?",
                        "Она заблокирована, я обновлю ключи завтра.", "Отлично. Можешь обновить инструкцию?", "Конечно, сделаю к пятнице."]),
]
for (a, b, text) in pairs where have.contains(a) && have.contains(b) {
    let d = try dialogue(a, b, text)
    // as the app does it: the speech kept on the tape (voice detection), the voices told apart on it, their turns back on the clock
    var tape = Tape(), state: VadStreamState?, speaking = false, level = VoiceLevel()
    var i0 = 0
    while i0 + 4096 <= d.audio.count {
        let x = Array(d.audio[i0..<i0 + 4096])
        if let r = await Engine.shared.speech(level.adjust(x).heard, state) { state = r.state; speaking = speaking ? r.p >= 0.35 : r.p >= 0.5 }
        tape.add(x, ms: Double(i0) / 16, speech: speaking)
        i0 += 4096
    }
    let t1 = Date()
    let offline = try await Engine.shared.diarize(tape.floats, maxSpeakers: nil).map { (start: tape.clock.ms(Int($0.start * 16000)) / 1000, end: tape.clock.ms(Int($0.end * 16000)) / 1000, spk: $0.spk) }
    let p1 = purity(offline, d.who)
    print(String(format: "speakers after the call (%@/%@): %d found, %.0f%% of speech right, tape %.0f of %.0f s, %.1f s", a, b, Set(offline.map(\.spk)).count, p1 * 100, tape.seconds, Double(d.audio.count) / 16000, Date().timeIntervalSince(t1)))
    check(tape.seconds >= Double(d.who.map { $0.to - $0.from }.reduce(0, +)) / 16000 * 0.95, "\(a)/\(b): the tape keeps the speech")
    let ls = try await LSEENDDiarizer(variant: .ami, stepSize: .step500ms)
    var liveTurns: [(start: Double, end: Double, spk: String)] = []
    var i = 0
    while i < d.audio.count {
        let x = Array(d.audio[i..<min(i + 8000, d.audio.count)])
        try ls.addAudio(x, sourceSampleRate: 16000)
        if let u = try ls.process() { liveTurns += u.finalizedSegments.map { (Double($0.startTime), Double($0.endTime), String($0.speakerIndex)) } }
        i += 8000
    }
    if let u = try ls.finalizeSession() { liveTurns += (u.finalizedSegments + u.tentativeSegments).map { (Double($0.startTime), Double($0.endTime), String($0.speakerIndex)) } }
    let p2 = purity(liveTurns, d.who)
    print(String(format: "live speakers (%@/%@): %d found, %.0f%% of speech right", a, b, Set(liveTurns.map(\.spk)).count, p2 * 100))
    check(max(p1, p2) >= 0.8, "\(a)/\(b): the voices told apart (live or after the call)")
}

// Ukrainian and English in one stream, as in a mixed call: each sentence in its own language.
if have.contains("Lesya") && have.contains("Samantha") {
    let mixed = [("Lesya", "Добрий день, колеги."), ("Samantha", "Good afternoon, let us start with the status."), ("Lesya", "Реліз запланований на понеділок."),
                 ("Samantha", "The migration is still blocked."), ("Lesya", "Олег оновить ключі до четверга."), ("Samantha", "Great, thank you everyone.")]
    var audio = quiet(16000)
    for (v, t) in mixed { audio += try say(v, 190, t) + quiet(9000) }
    let lv = try await live(audio, trace: true)
    let e = wer(mixed.map(\.1).joined(separator: " "), lv.text)
    print(String(format: "mixed Ukrainian and English, live: %.0f%%", e * 100))
    print("    \(lv.text)")
    check(e <= 0.25, "mixed languages live under 25% WER")
}

Engine.shared.release()
print(failures.isEmpty ? "all checks passed" : "\(failures.count) checks failed")
exit(failures.isEmpty ? 0 : 1)
