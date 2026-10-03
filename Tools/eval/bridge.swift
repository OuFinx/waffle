// Evaluation bridge: runs Waffle's own live-window code (Logic.swift) for two speakers, driven over stdin by eval.py, which owns the
// audio, the voice detection and the recognizer. One command per line, answers on stdout.
import Foundation

func f32(_ b64: Substring) -> [Float] {
    let d = Data(base64Encoded: String(b64))!
    return d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
}
func out(_ s: String) { FileHandle.standardOutput.write((s + "\n").data(using: .utf8)!) }

let echoGate = CommandLine.arguments.contains("--echo-gate")
var win: [String: Windower] = ["mic": Windower(), "sys": Windower()]
var clocks: [String: Int] = ["mic": 0, "sys": 0]
var sysAudio: [Float] = []
var passes: [Int: (src: String, pass: Pass)] = [:]
var nextId = 0
var lines: [Line] = []
var tapes: [String: Tape] = ["mic": Tape(), "sys": Tape()]
var polished: [Line] = []

func announce(_ src: String, _ ps: [Pass]) {
    for p in ps {
        passes[nextId] = (src, p)
        // the pass's audio is the last audio.count samples the speaker had when it was made
        out("P \(nextId) \(src) \(p.final ? 1 : 0) \(clocks[src]! - p.audio.count) \(p.audio.count) \(p.ctx)")
        nextId += 1
    }
}

while let raw = readLine() {
    let parts = raw.split(separator: " ", maxSplits: 3)
    switch parts[0] {
    case "C":  // C <src> <speech> <b64 samples>
        let src = String(parts[1]); var x = f32(parts[3]); let speech = parts[2] == "1"
        var gated = false
        if src == "sys" { sysAudio += x } else if echoGate {
            let end = clocks["mic"]! + x.count, from = end - x.count - 4800
            if from >= 0, end <= sysAudio.count, echoLike(x, Array(sysAudio[from..<end]), maxLag: 4800) { x = [Float](repeating: 0, count: x.count); gated = true }
        }
        tapes[src]!.add(x, ms: Double(clocks[src]!) / 16, speech: speech && !gated)
        clocks[src]! += x.count
        out("G \(gated ? 1 : 0)")
        announce(src, win[src]!.push(x, speech: speech && !gated))
        out("OK")
    case "D":  // D <id> <json [[start,end,text]]>
        let id = Int(parts[1])!
        let toks = (try! JSONSerialization.jsonObject(with: Data(String(parts[2...].joined(separator: " ")).utf8))) as! [[Any]]
        let segs: [Segment]? = toks.isEmpty && parts.count > 2 && parts[2] == "null" ? nil : toks.map { ($0[0] as! Double, $0[1] as! Double, $0[2] as! String) }
        let (src, p) = passes.removeValue(forKey: id)!
        for e in win[src]!.done(p, segs) {
            lines = replaceWindow(lines, src: src, w: e.start / 16, part: 1, final: e.final, segments: e.segments)
            out("E \(src) \(e.start) \(e.final ? 1 : 0) " + e.segments.map(\.text).joined())
        }
        out("OK")
    case "H":  // H <id> <json>: is the pass thin, and how many words it has
        let id = Int(parts[1])!
        let toks = (try! JSONSerialization.jsonObject(with: Data(String(parts[2...].joined(separator: " ")).utf8))) as! [[Any]]
        let segs: [Segment] = toks.map { ($0[0] as! Double, $0[1] as! Double, $0[2] as! String) }
        let (src, p) = passes[id]!
        out("H \(win[src]!.thin(p, segs) ? 1 : 0) \(win[src]!.words(p, segs))")
        out("OK")
    case "B":  // B <id> <json>: words of the bare pass
        let id = Int(parts[1])!
        let toks = (try! JSONSerialization.jsonObject(with: Data(String(parts[2...].joined(separator: " ")).utf8))) as! [[Any]]
        let segs: [Segment] = toks.map { ($0[0] as! Double, $0[1] as! Double, $0[2] as! String) }
        let (src, p) = passes[id]!
        out("B \(win[src]!.words(p.bare, segs))")
        out("OK")
    case "X":  // X <id>: the pass goes without its context
        let id = Int(parts[1])!
        let (src, p) = passes[id]!
        win[src]!.forgetContext(p)
        passes[id] = (src, p.bare)
        out("OK")
    case "F":  // F <src>
        announce(String(parts[1]), win[String(parts[1])]!.flush())
        out("OK")
    case "L":
        let rows = lines.map { ["t": $0.t, "src": $0.src, "text": $0.text, "final": $0.final] as [String: Any] }
        out(String(decoding: try! JSONSerialization.data(withJSONObject: rows), as: UTF8.self))
        out("OK")
    default: break
    }
}
