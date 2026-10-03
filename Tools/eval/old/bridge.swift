// The live windows as Waffle 0.3 did them (Recorder.swift's Segmenter, without the audio plumbing), over the same protocol as the new bridge.
import Foundation

func f32(_ b64: Substring) -> [Float] { let d = Data(base64Encoded: String(b64))!; return d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) } }
func out(_ s: String) { FileHandle.standardOutput.write((s + "\n").data(using: .utf8)!) }

struct OldPass { let gen: Int; let audio: [Float]; let w: Int; let final: Bool; let end: Int }
final class OldSegmenter {
    let frame = 480, updateAfter = 16000 * 3 / 2, updatePause = 10, updateMax = 16000 * 4, commitAfter = 16000 * 15, commitPause = 10, windowMax = 16000 * 30
    let silence: Float = 0.003
    var pending: [Float] = [], window: [Float] = []
    var clock = 0, windowStart = 0, sinceUpdate = 0, quietRun = 0, frames = 0
    var sumRms: Float = 0, peak: Float = 0
    var updating = false, generation = 0
    var out: [OldPass] = []
    func feed(_ x: [Float]) -> [OldPass] {
        out = []
        pending += x
        var i = 0
        while pending.count - i >= frame { step(Array(pending[i..<i + frame])); i += frame }
        pending.removeFirst(i)
        return out
    }
    func idle(_ skip: Int = 0) -> [OldPass] { out = []; if !window.isEmpty { submit(final: true) }; clock += skip; return out }  // the clock resyncs after a gap
    private func step(_ f: [Float]) {
        let rms = (f.reduce(0) { $0 + $1 * $1 } / Float(frame)).squareRoot()
        if window.isEmpty { windowStart = clock }
        window += f; sinceUpdate += frame; frames += 1; sumRms += rms; peak = max(peak, rms)
        quietRun = rms < max(0.002, 0.2 * sumRms / Float(frames)) ? quietRun + 1 : 0
        clock += frame
        if window.count >= windowMax || (window.count >= commitAfter && quietRun >= commitPause) { submit(final: true) }
        else if (sinceUpdate >= updateAfter && quietRun >= updatePause) || sinceUpdate >= updateMax { submit(final: false) }
    }
    private func submit(final: Bool) {
        sinceUpdate = 0
        if peak < silence { if final || window.count >= commitAfter { reset() }; return }
        if !final && updating { return }
        if !final { updating = true }
        out.append(OldPass(gen: generation, audio: window, w: windowStart, final: final, end: clock))
        if final { reset() }
    }
    private func reset() { window = []; frames = 0; sumRms = 0; peak = 0; quietRun = 0; generation += 1 }
    /// the async completion of Recorder 0.3: lock sentences, cut the window
    func done(_ p: OldPass, _ segs: [Segment]) -> [(w: Int, final: Bool, segs: [Segment])] {
        var r: [(w: Int, final: Bool, segs: [Segment])] = []
        if !p.final && p.gen == generation {
            let now = sentences(segs)
            let n = lockableSentences(now, audioEnd: Double(p.audio.count) / 16000)
            if n > 0 {
                let last = now[n - 1], cut = min(Int((last.end + (last.next ?? last.end)) / 2 * 16000), window.count)
                let shift = Double(cut) / 16000
                window.removeFirst(cut); windowStart += cut
                r.append((p.w, true, Array(segs[..<last.tokenEnd])))
                r.append((windowStart, false, segs[last.tokenEnd...].map { ($0.start - shift, $0.end - shift, $0.text) }))
            } else { r.append((p.w, false, segs)) }
        } else { r.append((p.w, p.final, segs)) }
        if !p.final { updating = false }
        return r
    }
}

var seg: [String: OldSegmenter] = ["mic": OldSegmenter(), "sys": OldSegmenter()]
var passes: [Int: (String, OldPass)] = [:], nextId = 0, lines: [Line] = []
func announce(_ src: String, _ ps: [OldPass]) {
    for p in ps { passes[nextId] = (src, p); out("P \(nextId) \(src) \(p.final ? 1 : 0) \(p.end - p.audio.count) \(p.audio.count) 0"); nextId += 1 }
}
while let raw = readLine() {
    let parts = raw.split(separator: " ", maxSplits: 3)
    switch parts[0] {
    case "C": let src = String(parts[1]); out("G 0"); announce(src, seg[src]!.feed(f32(parts[3]))); out("OK")
    case "I": announce(String(parts[1]), seg[String(parts[1])]!.idle(Int(parts[2])!)); out("OK")
    case "D":
        let id = Int(parts[1])!
        let toks = (try! JSONSerialization.jsonObject(with: Data(String(parts[2...].joined(separator: " ")).utf8))) as! [[Any]]
        let segs: [Segment] = toks.map { ($0[0] as! Double, $0[1] as! Double, $0[2] as! String) }
        let (src, p) = passes.removeValue(forKey: id)!
        for e in seg[src]!.done(p, segs) {
            lines = replaceWindow(lines, src: src, w: e.w / 16, part: 1, final: e.final, segments: e.segs)
            out("E \(src) \(e.w) \(e.final ? 1 : 0) " + e.segs.map(\.text).joined())
        }
        out("OK")
    case "F": announce(String(parts[1]), seg[String(parts[1])]!.idle()); out("OK")
    case "L":
        out(String(decoding: try! JSONSerialization.data(withJSONObject: lines.map { ["t": $0.t, "src": $0.src, "text": $0.text, "final": $0.final] as [String: Any] }), as: UTF8.self)); out("OK")
    default: break
    }
}
