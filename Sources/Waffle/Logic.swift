// Pure logic, no UI and no files: transcript assembly, summary parsing, prompts, dates, Markdown. Tests/main.swift checks it.
import Foundation

/// One sentence of the transcript. `w` is the start of the recognition window it came from; each new pass over a window replaces its lines.
struct Line: Codable, Equatable, Hashable {
    var t: Int  // epoch ms
    var src: String  // "mic" (Me) or "sys" (Them)
    var text: String
    var part: Int
    var final: Bool
    var w: Int?
    var spk: String? = nil  // who of "Them" said it, from speaker diarization: "<part>-<n>"
}

/// A stretch of system audio in which one voice spoke, from the diarizer. Times are epoch ms.
struct Turn: Equatable { var start: Int; var end: Int; var spk: String }

/// Who said each "Them" line: the diarized voice that overlaps it most. A line is taken to last until the next "Them" line starts
/// (at most 10 s; the last one 4 s). Lines no turn covers keep what they had.
/// It runs on every recognition pass of a long meeting, so each line only looks at the turns near it (turns sorted by start).
func labelSpeakers(_ lines: [Line], _ turns: [Turn]) -> [Line] {
    guard !turns.isEmpty else { return lines }
    let turns = zip(turns, turns.dropFirst()).allSatisfy { $0.start <= $1.start } ? turns : turns.sorted { $0.start < $1.start }
    let longest = turns.map { $0.end - $0.start }.max() ?? 0
    let sys = lines.indices.filter { lines[$0].src == "sys" }
    var out = lines
    for (k, i) in sys.enumerated() {
        let s = lines[i].t, e = k + 1 < sys.count ? max(min(lines[sys[k + 1]].t, s + 10000), s + 500) : s + 4000
        var overlap: [String: Int] = [:]
        // Turns that start before s - longest also end before s: skip them all with a binary search.
        var j = firstIndex(turns.count) { turns[$0].start >= s - longest }
        while j < turns.count, turns[j].start < e {
            let t = turns[j]
            if t.end > s { overlap[t.spk, default: 0] += min(t.end, e) - max(t.start, s) }
            j += 1
        }
        if let top = overlap.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }) { out[i].spk = top.key }
    }
    return out
}

/// The first index in 0..<count where `ok` holds, for an `ok` that is false and then true; count if it never holds.
func firstIndex(_ count: Int, where ok: (Int) -> Bool) -> Int {
    var lo = 0, hi = count
    while lo < hi { let mid = (lo + hi) / 2; if ok(mid) { hi = mid } else { lo = mid + 1 } }
    return lo
}

/// What each voice of "Them" is called: the name the user gave it, else "Speaker N" in order of first appearance. A single unnamed
/// voice is just "Them". A voice "@Name" (lines the call window named, see labelFromScreen) is called by that name.
func speakerNames(_ lines: [Line], names: [String: String]) -> [String: String] {
    var order: [String] = [], out: [String: String] = [:]
    for l in lines where l.src == "sys" {
        guard let s = l.spk, out[s] == nil, !order.contains(s) else { continue }
        if s.hasPrefix("@") { out[s] = names[s] ?? String(s.dropFirst()) } else { order.append(s) }
    }
    for (i, s) in order.enumerated() { out[s] = names[s] ?? (order.count == 1 && out.isEmpty ? "Them" : "Speaker \(i + 1)") }
    return out
}

func label(_ l: Line, _ names: [String: String]) -> String { l.src == "mic" ? "Me" : l.spk.flatMap { names[$0] } ?? "Them" }

typealias Segment = (start: Double, end: Double, text: String)


private func regex(_ p: String, _ o: NSRegularExpression.Options = []) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: o) }
// Lines that are only a sound mark ("[music]", "(laughs)") or punctuation. Parakeet does not make up the subtitle credits Whisper did
// ("thanks for watching"), so real speech like "Thank you." stays.
private let junk = regex(#"^\W*(\[[^\]]*\]|\([^)]*\))\W*$|^\W+$"#, .caseInsensitive)
private let wordRe = regex(#"\w+"#)

private func all(_ re: NSRegularExpression, _ s: String) -> [NSTextCheckingResult] { re.matches(in: s, range: NSRange(location: 0, length: (s as NSString).length)) }

/// Recognizer segments -> one entry per sentence, as (ms from the window start, text). Segments can break mid-word, so their raw text is
/// joined first, then split. A sentence is timed by interpolating its position inside the segment it starts in.
func splitSentences(_ segments: [Segment]) -> [(Int, String)] {
    var text = "", spans: [(a: Int, b: Int, start: Double, end: Double)] = []
    for s in segments {
        let a = (text as NSString).length
        text += s.text
        spans.append((a, (text as NSString).length, s.start, s.end))
    }
    guard let last = spans.last else { return [] }
    let ns = text as NSString
    return sentenceRanges(text).compactMap { r in
        let raw = ns.substring(with: r)
        let piece = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let at = r.location + ((raw as NSString).length - (raw.drop { $0.isWhitespace } as Substring).utf16.count)
        let sp = spans.first { $0.a <= at && at < $0.b } ?? last
        let off = Int((sp.start + (sp.end - sp.start) * Double(at - sp.a) / Double(max(sp.b - sp.a, 1))) * 1000)
        return piece.isEmpty || junk.firstMatch(in: piece, range: NSRange(location: 0, length: (piece as NSString).length)) != nil ? nil : (off, piece)
    }
}

/// Words that end with a dot inside a sentence ("Mr. Smith", "at 3 p.m. tomorrow", "і т.д."), lowercased, without the last dot.
private let abbreviations: Set<String> = ["mr", "mrs", "ms", "dr", "prof", "st", "vs", "e.g", "i.e", "a.m", "p.m", "jr", "sr", "inc", "ltd", "approx",
                                          "т.д", "т.п", "т.ч", "напр", "див", "ім", "вул", "проф", "т.е", "т.к", "см"]

/// The text ends a sentence: ".!?…" (and the Greek question mark ";" in Greek text), not after an abbreviation or an initial ("J.").
func endsSentence(_ text: String) -> Bool {
    let t = text.trimmingCharacters(in: .whitespaces)
    guard let c = t.last else { return false }
    if c == ";" { return t.unicodeScalars.contains { (0x370...0x3FF).contains($0.value) } }
    guard ".!?…".contains(c) else { return false }
    guard c == ".", let word = t.split(whereSeparator: \.isWhitespace).last.map({ String($0.dropLast()) }) else { return true }
    if abbreviations.contains(word.lowercased()) { return false }
    return !(word.count == 1 && word.first!.isUppercase)
}

/// The sentences of a text as UTF-16 ranges: each ends where endsSentence says, before a space or the end.
func sentenceRanges(_ text: String) -> [NSRange] {
    let ns = text as NSString, n = ns.length
    var out: [NSRange] = [], from = 0, i = 0
    func space(_ c: unichar) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 || c == 0xA0 }
    while i < n {
        let c = ns.character(at: i)
        if (c == 46 || c == 33 || c == 63 || c == 0x2026 || c == 59), i + 1 == n || space(ns.character(at: i + 1)),
           endsSentence(ns.substring(with: NSRange(location: from, length: i + 1 - from))) {
            out.append(NSRange(location: from, length: i + 1 - from)); from = i + 1
        }
        i += 1
    }
    if from < n, !ns.substring(from: from).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(NSRange(location: from, length: n - from)) }
    return out.filter { !ns.substring(with: $0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

func words(_ t: String) -> [String] {
    let lower = t.lowercased(), ns = lower as NSString
    return all(wordRe, lower).map { ns.substring(with: $0.range) }
}

/// How many words of `a` appear in `b` in the same order (longest common subsequence).
func commonRun(_ a: [String], _ b: [String]) -> Int {
    guard !a.isEmpty, !b.isEmpty else { return 0 }
    var prev = [Int](repeating: 0, count: b.count + 1)
    for x in a {
        var cur = [Int](repeating: 0, count: b.count + 1)
        for (j, y) in b.enumerated() { cur[j + 1] = x == y ? prev[j] + 1 : max(prev[j + 1], cur[j]) }
        prev = cur
    }
    return prev[b.count]
}

/// A "Me" line that is the speakers' sound coming back into the mic: it starts while the same words of that "Them" line were said (from a
/// second before the line to a second after the point where the rest of the line is as long as the "Me" line, about 0.4 s a word),
/// repeating most of it in order. Short lines (1-2 words) count only when they
/// start with the "Them" line, where echo cancellation lets the first moment through; a short "Yes." or "Okay." a moment later is an answer.
func isEcho(_ mine: [String], at t: Int, them: [String], at s: Int) -> Bool {
    guard !mine.isEmpty, !them.isEmpty else { return false }
    if mine.count <= 2 { return abs(t - s) <= 600 && commonRun(mine, them) == mine.count }
    guard t >= s - 1000, t <= s + max(0, them.count - mine.count) * 400 + 1000 else { return false }
    return Double(commonRun(mine, them)) >= 0.7 * Double(mine.count)
}

/// On speakers the mic also hears the other side: drop "Me" lines that are an echo of a "Them" line (see isEcho).
func dropEcho(_ lines: [Line]) -> [Line] {
    let them = lines.filter { $0.src == "sys" }.map { ($0.t, words($0.text)) }
    return lines.filter { l in
        guard l.src == "mic" else { return true }
        let mine = words(l.text)
        return !them.contains { isEcho(mine, at: l.t, them: $0.1, at: $0.0) }
    }
}

/// A new recognition pass over one speaker's window: its lines replace the ones from the previous pass of the same window.
func replaceWindow(_ lines: [Line], src: String, w: Int, part: Int, final: Bool, segments: [Segment], echoMs: Int = 30000) -> [Line] {
    let fresh = splitSentences(segments).map { Line(t: w + $0.0, src: src, text: $0.1, part: part, final: final, w: w) }
    let all = (lines.filter { !($0.w == w && $0.src == src) } + fresh).sorted { $0.t < $1.t }
    // Every pass so far left the transcript free of echoes, so only lines near the new ones can be echoes now (an echo sits within a
    // long sentence of its "Them" line). The rest of a long meeting is not looked at again.
    guard let from = fresh.map(\.t).min() else { return all }
    let cut = firstIndex(all.count) { all[$0].t >= from - 2 * echoMs }
    return Array(all[..<cut]) + dropEcho(Array(all[cut...]))
}

/// One sentence of a recognition pass: its text, the index after its last token, when it starts and ends, and when the next token starts.
typealias Sentence = (text: String, tokenEnd: Int, start: Double, end: Double, next: Double?)

/// Sentences of one recognition pass over recognizer tokens (see endsSentence).
func sentences(_ tokens: [Segment]) -> [Sentence] {
    var out: [Sentence] = [], text = "", start = 0.0
    for (i, t) in tokens.enumerated() {
        if text.trimmingCharacters(in: .whitespaces).isEmpty { start = t.start }
        text += t.text
        let next = i + 1 < tokens.count ? tokens[i + 1] : nil
        if next == nil || (next!.text.hasPrefix(" ") && endsSentence(text)) {
            let s = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if !s.isEmpty { out.append((s, i + 1, start, t.end, next?.start)) }
            text = ""
        }
    }
    return out
}

/// How many leading sentences of this pass can be locked for good: another sentence already follows each, each ends at least `margin`
/// seconds before the audio does, and each read the same in the pass before (`previous`), so one unlucky pass can not lock a wrong word.
/// Locked text is never re-transcribed, so a later change of language (or a worse guess on a longer window) can not rewrite it.
func lockableSentences(_ now: [Sentence], previous: [String]? = nil, audioEnd: Double, margin: Double = 0.8) -> Int {
    var n = 0
    while n < now.count - 1, now[n].end <= audioEnd - margin, previous.map({ n < $0.count && $0[n] == now[n].text }) ?? true { n += 1 }
    return n
}

/// Where to cut a window that grew too long without a lockable sentence: before the word (a token starting with a space) after the
/// widest pause between `from` and `to` seconds. nil when no word starts there.
func forcedCut(_ tokens: [Segment], from: Double, to: Double) -> Int? {
    var best: (i: Int, gap: Double)?
    for i in 1..<max(1, tokens.count) where tokens[i].text.hasPrefix(" ") && tokens[i].start >= from && tokens[i].start <= to {
        let gap = tokens[i].start - tokens[i - 1].end
        if best == nil || gap > best!.gap { best = (i, gap) }
    }
    return best?.i
}

/// Claude's reply -> (title, folders, speaker names, notes). The first lines may be "TITLE: ...", "FOLDERS: a, b" and
/// "SPEAKERS: Speaker 1 = Oleg, Speaker 2 = Maryna".
func parseSummary(_ text: String) -> (title: String?, folders: [String]?, speakers: [String: String], notes: String) {
    var lines = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
    var title: String?, folders: [String]?, speakers: [String: String] = [:]
    while let first = lines.first, ["TITLE:", "FOLDERS:", "SPEAKERS:"].contains(where: first.hasPrefix) {
        lines.removeFirst()
        let value = String(first.drop { $0 != ":" }.dropFirst())
        if first.hasPrefix("TITLE:") {
            title = value.components(separatedBy: "||")[0].trimmingCharacters(in: .whitespaces)
        } else if first.hasPrefix("FOLDERS:") {
            folders = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        } else {
            for pair in value.split(separator: ",") {
                let kv = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if kv.count == 2, !kv[0].isEmpty, !kv[1].isEmpty { speakers[kv[0]] = kv[1] }
            }
        }
    }
    return (title, folders, speakers, lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
}

// MARK: dates, always 24-hour

private func formatter(_ pattern: String) -> DateFormatter {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = pattern
    return f
}
let idFormat = formatter("yyyy-MM-dd_HH-mm-ss")
private let clockFormat = formatter("HH:mm:ss"), hmFormat = formatter("HH:mm"), dayMonth = formatter("d MMM")
private let weekdayFormat = formatter("EEEE, d MMM")
/// The meeting list's day headings: "Today", "Yesterday", "Monday, 28 Sep".
func dayHeading(_ d: Date, now: Date = Date()) -> String {
    let cal = Calendar.current
    if cal.isDate(d, inSameDayAs: now) { return "Today" }
    if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(d, inSameDayAs: y) { return "Yesterday" }
    return weekdayFormat.string(from: d)
}
private let fullFormat = formatter("EEE, d MMMM yyyy 'at' HH:mm"), longFormat = formatter("EEEE d MMMM yyyy"), promptDate = formatter("EEEE dd MMMM yyyy")

func meetingDate(_ id: String) -> Date { idFormat.date(from: id) ?? .distantPast }
func clock(_ ms: Int) -> String { clockFormat.string(from: Date(timeIntervalSince1970: Double(ms) / 1000)) }
func hm(_ d: Date) -> String { hmFormat.string(from: d) }
/// "Meeting 29 Sep, 15:29"
func fallbackTitle(_ id: String) -> String { "Meeting \(dayMonth.string(from: meetingDate(id))), \(hm(meetingDate(id)))" }
/// "Tue, 29 September 2026 at 16:04"
func fullDate(_ id: String) -> String { fullFormat.string(from: meetingDate(id)) }
/// "29 Sep"
func shortDay(_ d: Date) -> String { dayMonth.string(from: d) }
/// "Tuesday 29 September 2026"
func longDate(_ id: String) -> String { longFormat.string(from: meetingDate(id)) }
func promptDateLine(_ id: String) -> String { "Meeting date: \(promptDate.string(from: meetingDate(id)))" }

/// For Claude and transcript.md: "[HH:MM:SS] Me: ..." and "[HH:MM:SS] Oleg: ..." (or "Speaker 2", or "Them").
func transcriptText(_ lines: [Line], names: [String: String] = [:]) -> String {
    let n = speakerNames(lines, names: names)
    return lines.map { "[\(clock($0.t))] \(label($0, n)): \($0.text)" }.joined(separator: "\n")
}

/// The transcript to paste anywhere: "Who: what they said", one line per turn (a run of lines from one speaker is one turn).
func transcriptCopy(_ lines: [Line], names: [String: String] = [:]) -> String {
    let n = speakerNames(lines, names: names)
    var turns: [(who: String, text: String)] = []
    for l in lines {
        let who = label(l, n)
        if turns.last?.who == who { turns[turns.count - 1].text += " " + l.text } else { turns.append((who, l.text)) }
    }
    return turns.map { "\($0.who): \($0.text)" }.joined(separator: "\n")
}

/// "12:34", or "1:02:03" past an hour.
func elapsed(_ secs: Int) -> String {
    let s = max(0, secs)
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}

// MARK: Markdown (ponytail: the subset the summaries use: headings, nested bullets, bold)

enum Block: Hashable {
    case heading(String)
    case bullet(level: Int, text: String)  // level 0 is the outermost
    case paragraph(String)
}

private let bulletRe = regex(#"^(\s*)[-*] (.*)$"#), headingRe = regex(#"^#{1,6} "#), boldRe = regex(#"\*\*(.+?)\*\*"#)

func blocks(_ text: String) -> [Block] {
    text.components(separatedBy: "\n").compactMap { raw in
        let ns = raw as NSString, r = NSRange(location: 0, length: ns.length)
        if let m = bulletRe.firstMatch(in: raw, range: r) {
            return .bullet(level: m.range(at: 1).length / 2, text: ns.substring(with: m.range(at: 2)))
        }
        if headingRe.firstMatch(in: raw, range: r) != nil { return .heading(raw.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)) }
        return raw.trimmingCharacters(in: .whitespaces).isEmpty ? nil : .paragraph(raw)
    }
}

private func inlineHTML(_ s: String) -> String {
    let e = s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    return boldRe.stringByReplacingMatches(in: e, range: NSRange(location: 0, length: (e as NSString).length), withTemplate: "<b>$1</b>")
}

/// HTML for the clipboard. Lists are really nested (<ul> inside <li>) so Slack keeps the nesting; headings become bold lines.
func summaryHTML(_ text: String) -> String {
    var html = "", depth = 0
    func close(to d: Int) { while depth > d { html += "</li></ul>"; depth -= 1 } }
    for b in blocks(text) {
        switch b {
        case let .bullet(level0, t):
            let level = level0 + 1
            if level > depth { while depth < level { html += "<ul><li>"; depth += 1 } } else { close(to: level); html += "</li><li>" }
            html += inlineHTML(t)
        case let .heading(t): close(to: 0); html += "<p><b>\(inlineHTML(t))</b></p>"
        case let .paragraph(t): close(to: 0); html += "<p>\(inlineHTML(t))</p>"
        }
    }
    close(to: 0)
    return html
}

/// Folder emojis: each new folder gets one at random (ones not in use first); a folder's page can pick another.
let folderEmojis = ["🚀", "📌", "🧭", "🛠️", "📊", "🗂️", "💡", "🔥", "🌱", "🧪", "🎯", "📣", "🧩", "🔒", "☁️", "🐳", "⚙️", "📦", "🗓️", "🤝",
                    "🧠", "📈", "🐛", "🛰️", "🌊", "🍀", "🦊", "🐝", "🎨", "⭐️", "🍕", "🎧", "🏔️", "🌈", "🦉", "🍋"]

func randomFolderEmoji(avoiding used: some Collection<String> = [String]()) -> String {
    (folderEmojis.filter { !used.contains($0) }.randomElement() ?? folderEmojis.randomElement())!
}

// MARK: prompts

/// Rules for every summary, whatever the template: who is who, English, no invented facts.
let summaryBase = """
You turn a meeting transcript and the user's own rough notes into meeting notes.
Speaker "Me" is the user (their microphone). Every other label is someone else on the call: a name, "Speaker 2" (a voice told apart by sound, name unknown), or "Them" (everyone else together).
A label that first shows up partway through is a new voice joining the conversation. Lines labelled "Them" can be several people: tell them apart by what they say and by turn-taking (a question and its answer, a greeting, someone addressed by name), and credit a point to a person only when that is clear.
If the input lists the people seen in the call window (the names Zoom or Teams showed), they are most likely the people in the call (the list can hold a stray non-name): spell their names as listed, and use them to tell who a voice is when the conversation supports it.
If the input has the calendar event, its title is what the meeting was planned as and its invited people are likely in the call (not all of them may have joined); spell their names as listed.
The transcript is machine-made: fix obvious recognition errors from context, never invent facts.
The meeting may be in any language, or several. Always write the notes in English; keep names, product names and ticket numbers as spoken.
The user's notes show what they care about: make sure those topics are covered and expanded with details from the transcript.
Use 24-hour time only, never AM/PM. Resolve relative dates ("next Monday") using the meeting date given in the input. No intro and no closing remarks.
"""

/// Always appended: the app needs the title, folder and speaker lines to file the meeting.
let summaryFormat = """
Folders: the input lists the user's existing folders and the folders this meeting is already in.
If the meeting clearly belongs to other existing folders too, pick them; never invent new folder names.

Output exactly this layout:
line 1: "TITLE: <3-7 word English title of the meeting>"
line 2: "FOLDERS: <comma-separated existing folder names this meeting belongs to, including the given ones; empty if none>"
line 3: "SPEAKERS: <for transcript labels like "Speaker 2" whose real name is clear from the conversation (someone addresses them by name, they introduce themselves, or only one of the people seen in the call window fits what they say): "Speaker 2 = Oleg", comma-separated; empty if none is clear; never guess>"
then the notes, in Markdown. In the notes, call people by those names.
"""

/// The system prompt for a meeting's notes: the fixed rules, the template's structure and style, the fixed output layout.
func summarySystem(template: Template) -> String {
    summaryBase + "\n\nStructure and style (template \u{201C}\(template.name)\u{201D}):\n" + template.text + "\n\n" + summaryFormat
}

// MARK: summary templates

struct Template: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var text: String
    var about: String? = nil  // one line for the list (built-in ones); the user's own show their first line
    var emoji: String? = nil

    /// "🧍 Standup": how a template shows in lists and menus, so they are easy to tell apart.
    var label: String { "\(emoji ?? "📝") \(name)" }
}

let templateEmojis = ["📝", "🗒️", "📋", "📌", "🧩", "🎯", "💡", "📎", "✏️", "🧭", "📊", "🗂️", "🛠️", "🌱", "🔍", "📣", "🧪", "🗓️"]

/// templates.json: the user's own templates, their changes to built-in ones, the default for meeting notes, each folder's report template.
struct TemplateLibrary: Codable, Equatable {
    var custom: [Template] = []
    var edited: [String: Template] = [:]  // built-in id -> the user's version of it
    var defaultId = "waffle"
    var folders: [String: String] = [:]

    init() {}
    /// Missing keys are fine: a file from an earlier version must still load (and not be taken for the old format and migrated again).
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        custom = try c.decodeIfPresent([Template].self, forKey: .custom) ?? []
        edited = try c.decodeIfPresent([String: Template].self, forKey: .edited) ?? [:]
        defaultId = try c.decode(String.self, forKey: .defaultId)  // present in every file this format wrote
        folders = try c.decodeIfPresent([String: String].self, forKey: .folders) ?? [:]
    }

    var all: [Template] { builtinTemplates.map { edited[$0.id] ?? $0 } + custom }
    func isEdited(_ id: String) -> Bool { edited[id] != nil }
    func original(_ id: String) -> Template? { builtinTemplates.first { $0.id == id } }
    /// That template, or the default when it is gone.
    func template(_ id: String?) -> Template { all.first { $0.id == id } ?? all.first { $0.id == defaultId } ?? builtinTemplates[0] }
    var defaultTemplate: Template { template(defaultId) }
    func isBuiltin(_ id: String) -> Bool { builtinTemplates.contains { $0.id == id } }
}

/// The earlier templates.json ({folder: text}) and the earlier custom summary instructions become the user's own templates.
func migrateTemplates(_ old: [String: Any], customPrompt: String) -> TemplateLibrary {
    var lib = TemplateLibrary()
    for (folder, text) in old.compactMapValues({ $0 as? String }).sorted(by: { $0.key < $1.key }) {
        lib.custom.append(Template(id: "folder-\(folder)", name: folder, text: text))
        lib.folders[folder] = "folder-\(folder)"
    }
    let own = customPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    if !own.isEmpty {
        lib.custom.insert(Template(id: "my-instructions", name: "My instructions", text: own), at: 0)
        lib.defaultId = "my-instructions"
    }
    return lib
}

let builtinTemplates: [Template] = [
    Template(id: "waffle", name: "Waffle notes", text: """
    Topics as level-1 headings, with the owner or presenter in parentheses: # Firewall Upgrades (Joseph Lomax)

    Under each heading:
    - Only bullets, no paragraphs
    - Short, dense, factual fragments: "Scheduled for Monday 5th October, 11:00"
    - Details as sub-bullets (2 spaces): reasons, dates, impact, who confirmed what, what is blocked and why
    - Concrete facts: names, ticket numbers, versions, environments, dates, durations, numbers
    - The owner in parentheses when known: "Server-side fix ready (Oleg)"

    Always end with # Next Steps:
    - **Rotate database credentials** (Oleg)

    Example:
    # Database Credentials (Oleg)
    - API migration blocked: database credentials expired
      - Rotation planned by Thursday 1st October
    """, about: "Topics with owners, terse bullets, Next Steps", emoji: "🧇"),
    Template(id: "brief", name: "Brief", text: """
    Very short notes, nothing else:

    # Summary
    - At most 5 bullets: the main outcomes and decisions

    # Next Steps
    - **Action** (Owner)
    """, about: "Up to 5 key outcomes and the actions", emoji: "⚡️"),
    Template(id: "standup", name: "Standup", text: """
    Daily standup.

    One heading per person: # Name
    - Done since the last standup
    - Plan for today
    - Blockers, starting with **Blocked:**

    Skip small talk.
    # Next Steps: only blockers and explicit asks, with the owner
    """, about: "Per person: done, today, blockers", emoji: "🧍"),
    Template(id: "one-on-one", name: "One-on-one", text: """
    One-on-one meeting.

    # Updates
    # Feedback
    # Growth
    # Concerns
    # Next Steps: **Action** (Owner)

    Keep personal topics neutral and brief.
    """, about: "Updates, feedback, growth, concerns", emoji: "🤝"),
    Template(id: "status", name: "Project status", text: """
    Project status.

    # Status: one line, On track / At risk / Off track, and why
    # Progress
    # Risks and blockers
    # Decisions
    # Next Steps: **Action** (Owner, date)
    """, about: "On track or at risk, progress, risks, decisions", emoji: "🚦"),
    Template(id: "decisions", name: "Decision log", text: """
    Only what was decided.

    One heading per decision: # <decision>
    - What exactly
    - Why
    - Alternatives dropped
    - Who decided
    - From when it applies

    # Open questions
    # Next Steps: **Action** (Owner)
    """, about: "Each decision with why, who and when", emoji: "⚖️"),
    Template(id: "cab", name: "Change review (CAB)", text: """
    Change advisory board.

    One heading per change or ticket: # <ticket or change> (<owner>)
    - What changes
    - Environment or cluster
    - Scheduled date and 24-hour time window
    - Expected downtime or impact
    - Decision: approved / postponed / needs info, and why

    # Next Steps: follow-ups per owner
    """, about: "Per change: time window, impact, approval", emoji: "🔧"),
    Template(id: "incident", name: "Incident review", text: """
    Incident review. Be precise with times, services, versions and numbers.

    # Impact: what broke, who was affected, for how long
    # Timeline: 24-hour times
    # Root cause
    # Recovery
    # Follow-ups: **Action** (Owner)
    """, about: "Impact, timeline, root cause, follow-ups", emoji: "🚨"),
    Template(id: "customer", name: "Customer call", text: """
    Call with a customer or partner.

    # Context
    # Their requests and concerns
    # What we promised
    # Open questions
    # Next Steps: **Action** (Owner, date)
    """, about: "Their asks, our promises, open questions", emoji: "💼"),
    Template(id: "retro", name: "Retrospective", text: """
    Retrospective. Group similar points; keep each one short.

    # Went well
    # To improve
    # Ideas
    # Action items: **Action** (Owner)
    """, about: "Went well, to improve, action items", emoji: "🔁"),
]

let askPrompt = """
You help the user during or after a meeting. You get the transcript and the user's notes, then a question.
Speaker "Me" is the user; every other label (a name, "Speaker 2", "Them") is someone else on the call; "Them" can be several people. If the input lists the people seen in the call window or invited in the calendar, they are most likely the people in the call. The transcript is machine-made and may have recognition errors.
Answer briefly and only from the transcript; say so if it is not there. Reply in the language of the question.
"""

// MARK: names from the call window (Zoom, Microsoft Teams), see ScreenNames

/// Words of the call apps' own buttons and labels, and words that start sentences: a "name" with one of them is not a person.
private let appWords: Set<String> = [
    "share", "screen", "start", "stop", "video", "audio", "mute", "unmute", "muted", "unmuted", "chat", "participants", "people", "leave",
    "end", "meeting", "meetings", "more", "reactions", "react", "raise", "hand", "view", "gallery", "speaker", "record", "recording",
    "apps", "whiteboard", "whiteboards", "zoom", "teams", "microsoft", "camera", "mic", "microphone", "settings", "join", "rooms",
    "room", "calendar", "activity", "files", "help", "search", "notes", "captions", "security", "host", "options", "everyone",
    "waiting", "new", "window", "close", "minimize", "full", "exit", "show", "hide", "invite", "summary", "transcript", "breakout",
    "you", "your", "not", "no", "is", "are", "the", "this", "that", "and", "or", "of", "to", "in", "on", "talking", "speaking",
    "good", "morning", "afternoon", "evening", "hello", "hi", "thanks", "thank", "okay", "yes", "today", "tomorrow", "call", "calls",
    "home", "chats", "channel", "channels", "copilot", "phone", "contacts", "team", "general", "posts", "recap", "layout", "focus",
    "fullscreen", "about", "details", "avatars", "avatar", "preview", "devices", "blur", "effects", "keep", "annotate", "apply", "pinned",
    // meeting titles, which the window and calendar labels show next to the people
    "sync", "review", "standup", "stand-up", "planning", "sprint", "weekly", "daily", "monthly", "demo", "retro", "retrospective",
    "product", "design", "project", "update", "updates", "kickoff", "workshop", "interview", "training", "office", "hours", "all-hands",
    "town", "hall", "huddle", "catch-up", "status", "report", "roadmap", "strategy", "onboarding", "session", "webinar", "agenda",
    "check-in", "one-on-one", "standing", "sales", "support", "engineering", "marketing", "board", "committee", "personal",
]

/// A name as the call app shows it, without what the app adds: "Oleg Petrenko (Host)", "Oleg Petrenko, muted" -> "Oleg Petrenko".
/// nil when it does not look like a person's name: `minWords` to 4 words, each starting with a capital letter, letters only.
func personName(_ raw: String, minWords: Int = 2) -> String? {
    // "Petrenko, Oleg" (a company directory, Teams): surname first. "Oleg Petrenko, muted" is a name and a state.
    let halves = raw.components(separatedBy: CharacterSet(charactersIn: "(|[\n\u{2022}")).first?.split(separator: ",", maxSplits: 1).map(String.init) ?? []
    if halves.count == 2, let last = plainName(halves[0], minWords: 1), let first = plainName(halves[1], minWords: 1),
       last.split(separator: " ").count == 1, first.split(separator: " ").count <= 2 {
        return plainName(first + " " + last, minWords: minWords)
    }
    return plainName(raw, minWords: minWords)
}

private func plainName(_ raw: String, minWords: Int) -> String? {
    let cut = raw.components(separatedBy: CharacterSet(charactersIn: ",(|[\n\u{2022}")).first ?? raw
    let words = cut.split(whereSeparator: \.isWhitespace).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".:;!?\"")) }.filter { !$0.isEmpty }
    guard (minWords...4).contains(words.count), words.joined().count <= 40 else { return nil }
    for w in words {
        guard let f = w.first, f.isUppercase, w.allSatisfy({ $0.isLetter || $0 == "-" || $0 == "'" || $0 == "\u{2019}" }), !appWords.contains(w.lowercased()) else { return nil }
    }
    return words.joined(separator: " ")
}

private let talkingFirst = regex(#"^\s*(?:talking|speaking|говорить|говорит|розмовляє)\s*:\s*(.+)$"#, .caseInsensitive)
private let notTalking = regex(#"\b(?:not|не)\s+(?:speaking|talking|говорить|говорит|розмовляє)"#, .caseInsensitive)
private let selfMark = regex(#"^(.+?)\s*\((?:[^)]*,\s*)?(?:me|you|я|вы|ви)\)"#, .caseInsensitive)

/// The user's own name as the call window marks it: "Oleg Petrenko (Host, me)" (Zoom), "Oleg Petrenko (You)" (Teams), "(Я)".
func selfName(_ texts: [String]) -> String? {
    for t in texts where t.count <= 120 {
        let ns = t as NSString
        if let m = selfMark.firstMatch(in: t, range: NSRange(location: 0, length: ns.length)), let n = personName(ns.substring(with: m.range(at: 1)), minWords: 1) { return n }
    }
    return nil
}

private let talkingAfter = regex(#"^(.+?)(?:\s+is|\s*,|\s*\(|\s+-)?\s*(?:is\s+)?\b(?:speaking|talking|говорить|говорит|розмовляє)\b"#, .caseInsensitive)

/// Who the call window says is talking, from its labels or text: "Talking: Oleg Petrenko" (Zoom), "Oleg Petrenko is speaking",
/// "Oleg Petrenko, speaking", "Oleg Petrenko (speaking)", also in Ukrainian. One-word names count here.
func speakingNames(_ texts: [String]) -> [String] {
    var out: [String] = []
    for t in texts {
        let ns = t as NSString, r = NSRange(location: 0, length: ns.length)
        guard t.count <= 120, notTalking.firstMatch(in: t, range: r) == nil,
              let m = talkingFirst.firstMatch(in: t, range: r) ?? talkingAfter.firstMatch(in: t, range: r),
              let name = personName(ns.substring(with: m.range(at: 1)), minWords: 1), !out.contains(name) else { continue }
        out.append(name)
    }
    return out
}

/// The people the call window shows (video tiles, participant list): names of 2 to 4 capitalised words, in the order first seen.
func rosterNames(_ texts: [String]) -> [String] {
    var out: [String] = []
    // "Weekly Sync | Microsoft Teams", "Zoom Meeting - Oleg": window titles, not people
    for t in texts where t.count <= 80 && !t.contains("|") && !t.contains(" - ") { if let n = personName(t), !out.contains(n) { out.append(n) } }
    return out
}

/// Names for the voices of "Them" from who the call window showed as talking (t: epoch ms) during their turns. A voice gets a name when
/// it was shown in at least 3 looks and two thirds of the voice's looks; a name two voices would get goes to neither.
func screenSpeakers(_ turns: [Turn], _ talking: [(t: Int, name: String)]) -> [String: String] {
    guard !turns.isEmpty, !talking.isEmpty else { return [:] }
    let turns = zip(turns, turns.dropFirst()).allSatisfy { $0.start <= $1.start } ? turns : turns.sorted { $0.start < $1.start }
    let longest = turns.map { $0.end - $0.start }.max() ?? 0, lag = 1000  // the app shows a voice a moment after it starts
    var votes: [String: [String: Int]] = [:]
    for s in talking {
        var j = firstIndex(turns.count) { turns[$0].start >= s.t - longest - lag }
        while j < turns.count, turns[j].start <= s.t {
            if s.t < turns[j].end + lag { votes[turns[j].spk, default: [:]][s.name, default: 0] += 1 }
            j += 1
        }
    }
    var out: [String: String] = [:]
    for (spk, v) in votes {
        let total = v.values.reduce(0, +)
        if let top = v.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }), top.value >= 3, top.value * 3 >= total * 2 { out[spk] = top.key }
    }
    // A name two voices would get goes to both when they never talk at the same time (one person the diarizer split in two), else to neither.
    let byName = Dictionary(grouping: out.keys) { out[$0]! }
    func overlap(_ a: String, _ b: String) -> Bool {
        turns.contains { x in x.spk == a && turns.contains { y in y.spk == b && max(x.start, y.start) < min(x.end, y.end) } }
    }
    return out.filter { spk, name in
        let all = byName[name] ?? []
        return all.count == 1 || !all.contains { $0 != spk && overlap($0, spk) }
    }
}

/// Who the call window showed talking goes before the diarized voice: the live diarizer tells apart at most 4 voices, so on a bigger call
/// several people share one, and its name. A "Them" line gets the person the call window showed as the only one talking during it, as
/// the voice "@Name": with no voice, from 1 s before the line to 4 s after; with a voice that shows another name (`names`), from 1 s
/// after the line starts (the app shows a voice a moment late) until 1 s after the next line starts, at most 10 s. `talking` is in time order.
func labelFromScreen(_ lines: [Line], _ talking: [(t: Int, name: String)], names: [String: String] = [:]) -> [Line] {
    guard !talking.isEmpty else { return lines }
    func only(_ from: Int, _ to: Int) -> String? {
        var j = firstIndex(talking.count) { talking[$0].t >= from }, near = Set<String>()
        while j < talking.count, talking[j].t <= to { near.insert(talking[j].name); j += 1 }
        return near.count == 1 ? near.first : nil
    }
    var out = lines
    let sys = lines.indices.filter { lines[$0].src == "sys" }
    for (k, i) in sys.enumerated() {
        let t = out[i].t
        if let spk = out[i].spk, !spk.hasPrefix("@") {
            let end = k + 1 < sys.count ? min(lines[sys[k + 1]].t, t + 9000) + 1000 : t + 4000
            if end > t + 1000, let name = only(t + 1000, end), names[spk] != name { out[i].spk = "@" + name }
        } else if let name = only(t - 1000, t + 4000) {
            out[i].spk = "@" + name
        }
    }
    return out
}

/// Names of voices that stay once given: the ones settled so far, plus what the call window names now for a voice without a name, when
/// no other voice has that name. A name never moves to another voice or goes away as more looks come in.
func settleNames(_ settled: [String: String], _ fresh: [String: String]) -> [String: String] {
    var out = settled
    let shared = Set(Dictionary(grouping: fresh.values) { $0 }.filter { $0.value.count > 1 }.keys)  // one person split in two voices
    for (spk, name) in fresh.sorted(by: { $0.key < $1.key }) where out[spk] == nil && (!out.values.contains(name) || shared.contains(name)) { out[spk] = name }
    return out
}

/// Lines labelled again (`after`, from `before`) keep a person's name once they show one: a late turn or the next line can move a
/// line to a voice with no name, which would turn "Oleg" back into "Speaker 2" or "Them". A line the call window named ("@Oleg") that
/// a voice with no name now covers names that voice instead, so its other lines get the name too. Returns the lines and the voices'
/// names with the ones learned.
func keepNamed(_ before: [Line], _ after: [Line], _ names: [String: String]) -> (lines: [Line], names: [String: String]) {
    var names = names, out = after
    func shown(_ s: String?) -> String? { s.flatMap { names[$0] ?? ($0.hasPrefix("@") ? String($0.dropFirst()) : nil) } }
    for i in out.indices where i < before.count && before[i].t == after[i].t && before[i].src == after[i].src && before[i].spk != after[i].spk {
        guard let old = shown(before[i].spk) else { continue }
        if before[i].spk!.hasPrefix("@"), let v = after[i].spk, !v.hasPrefix("@"), names[v] == nil, !names.values.contains(old) { names[v] = old }
        // The call window may take a line from a voice's name (see labelFromScreen), not from another name it showed.
        if shown(after[i].spk) != old && !(after[i].spk?.hasPrefix("@") == true && !before[i].spk!.hasPrefix("@")) { out[i].spk = before[i].spk }
    }
    return (out, names)
}

/// The people seen in a call with the names the user corrected (old -> new), once each, sorted.
func renamePeople(_ people: [String], _ renamed: [String: String]) -> [String] { Set(people.map { renamed[$0] ?? $0 }).sorted() }

/// A screenshot as RGBA bytes, rows from the top.
struct Pixels {
    var w: Int, h: Int, rgba: [UInt8]
    func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) { let i = (y * w + x) * 4; return (Int(rgba[i]), Int(rgba[i + 1]), Int(rgba[i + 2])) }
}

/// Hue in degrees of an RGB colour, nil for a dull one (grey, dark, washed out).
private func frameHue(_ c: (Int, Int, Int)) -> Double? {
    let mx = max(c.0, c.1, c.2), mn = min(c.0, c.1, c.2), d = Double(mx - mn)
    guard mx >= 110, mx - mn >= 40, d / Double(mx) >= 0.18 else { return nil }
    let r = Double(c.0), g = Double(c.1), b = Double(c.2)
    let h = mx == c.0 ? (g - b) / d : mx == c.1 ? 2 + (b - r) / d : 4 + (r - g) / d
    let deg = (h * 60 + 360).truncatingRemainder(dividingBy: 360)
    // The active-speaker colours only: Zoom green / yellow-green, Teams violet. Not red (annotations), not amber (Teams raised hand).
    return (50...160).contains(deg) || (215...265).contains(deg) ? deg : nil
}

private func sameHue(_ a: Double, _ b: Double) -> Bool { let d = abs(a - b); return min(d, 360 - d) <= 25 }

/// The names the call app draws its active-speaker highlight around: a thin border of one colour on all sides of the name's tile (the
/// name in a corner of a video tile, or in the middle of a tile with the camera off), or a ring around the avatar just above the name
/// (Teams, camera off). `names`: what text recognition read, with its box in pixels (top-left origin). More than two framed: none.
func framedNames(_ img: Pixels, _ names: [(name: String, x: Int, y: Int, w: Int, h: Int)]) -> [String] {
    guard img.w > 0, img.h > 0, img.rgba.count >= img.w * img.h * 4 else { return [] }
    func inside(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < img.w && y < img.h }
    /// Hue of a straight line of n pixels centred on (x, y), along (dx, dy), when 85% of it is one frame colour.
    func line(_ x: Int, _ y: Int, _ n: Int, _ dx: Int, _ dy: Int) -> Double? {
        guard inside(x - dx * n / 2, y - dy * n / 2), inside(x + dx * n / 2, y + dy * n / 2), let mid = frameHue(img.rgb(x, y)) else { return nil }
        var ok = 0
        for k in -n / 2...n / 2 { if let hh = frameHue(img.rgb(x + dx * k, y + dy * k)), sameHue(hh, mid) { ok += 1 } }
        return ok * 100 >= (n + 1) * 85 ? mid : nil
    }
    /// Walking from (x, y) along (dx, dy): the hue of the first thin border across the way and how far it is, of the given hue when
    /// there is one. Thin: a line across, gone 8 px further on and 5 px before (else it is the edge of a coloured area, like the violet
    /// rooms of Teams avatars).
    func border(_ x: Int, _ y: Int, _ dx: Int, _ dy: Int, _ n: Int, _ limit: Int, _ want: Double? = nil) -> (hue: Double, at: Int)? {
        var (px, py) = (x, y)
        for k in 1...max(1, limit) {
            px += dx; py += dy
            guard inside(px, py) else { return nil }
            guard let here = frameHue(img.rgb(px, py)), want.map({ sameHue($0, here) }) ?? true else { continue }
            guard let hh = line(px, py, n, dy, dx), want.map({ sameHue($0, hh) }) ?? true else { continue }
            let gone = { (o: Int) in !(line(px + dx * o, py + dy * o, n, dy, dx).map { sameHue($0, hh) } ?? false) }
            if gone(8) && gone(-5) { return (hh, k) }
        }
        return nil
    }
    func ringPoint(_ x: Double, _ y: Double, _ hue: Double) -> Bool {
        for oy in -3...3 { for ox in -3...3 where inside(Int(x) + ox, Int(y) + oy) {
            if let hh = frameHue(img.rgb(Int(x) + ox, Int(y) + oy)), sameHue(hh, hue) { return true }
        } }
        return false
    }
    var out: [String] = []
    for n in names where n.w > 2 && n.h > 2 && !out.contains(n.name) {
        let cx = n.x + n.w / 2, cy = n.y + n.h / 2, reach = max(img.w, img.h) / 2
        // Text on a button of a frame colour is not a framed name: the name's own background must not be that colour.
        var coloured = 0, all = 0
        for y in stride(from: n.y, to: n.y + n.h, by: 2) { for x in stride(from: n.x, to: n.x + n.w, by: 2) where inside(x, y) { all += 1; if frameHue(img.rgb(x, y)) != nil { coloured += 1 } } }
        guard coloured * 100 < all * 15 else { continue }
        // Tile: a border on at least 3 sides (a menu or the window edge can hide one), all of one colour.
        // The colour comes from the nearest side found (the one under a corner label), the others must be of that colour.
        let across = max(16, min(n.w, 60)), along = max(10, min(n.h * 2, 40))
        let rays = [(cx, n.y, 0, -1, across), (cx, n.y + n.h, 0, 1, across), (n.x, cy, -1, 0, along), (n.x + n.w, cy, 1, 0, along)]
        // A tile is much bigger than its name; a frame tight around the text is a selected button.
        if let hue = rays.compactMap({ border($0.0, $0.1, $0.2, $0.3, $0.4, reach) }).min(by: { $0.at < $1.at })?.hue {
            let found = rays.compactMap { border($0.0, $0.1, $0.2, $0.3, $0.4, reach, hue)?.at }
            if found.count >= 3, (found.max() ?? 0) >= max(30, n.h * 3) { out.append(n.name); continue }
        }
        // Avatar: the bottom of a ring a little above the name, its top a diameter higher, and the ring's sides; the avatar inside is not
        // the ring colour (an avatar of initials on a coloured disc is not a ring).
        var y = n.y - 1, bottom: Int?, hue = 0.0
        while y > max(0, n.y - max(40, n.h * 4)), bottom == nil { if let hh = frameHue(img.rgb(cx, y)) { bottom = y; hue = hh }; y -= 1 }
        guard let b = bottom else { continue }
        y = b - 6
        var top: Int?
        while y > max(0, b - 400), top == nil { if let hh = frameHue(img.rgb(cx, y)), sameHue(hh, hue) { top = y }; y -= 1 }
        guard let t = top, b - t >= max(24, n.h * 2) else { continue }
        // The column through the name is a chord (the name can be off centre, "Lynne Robbins (External)"): its middle is the ring's
        // middle row, where the ring's left and right give the centre and the radius.
        let mid = (b + t) / 2
        func side(_ dx: Int) -> Int? {
            var x = cx + dx * 4
            while inside(x, mid), abs(x - cx) < b - t {
                if let hh = frameHue(img.rgb(x, mid)), sameHue(hh, hue) { return x }
                x += dx
            }
            return nil
        }
        guard let xl = side(-1), let xr = side(1), xr - xl >= max(24, n.h * 2) else { continue }
        let r = Double(xr - xl) / 2, ox = Double(xl + xr) / 2, gap = max(5, r * 0.18)
        let angles = stride(from: 0.0, to: 2 * Double.pi, by: Double.pi / 4).map { (cos($0), sin($0)) }
        func at(_ a: (Double, Double), _ rr: Double) -> (Double, Double) { (ox + a.0 * rr, Double(mid) + a.1 * rr) }
        func ringHue(_ p: (Double, Double)) -> Bool { inside(Int(p.0), Int(p.1)) && (frameHue(img.rgb(Int(p.0), Int(p.1))).map { sameHue($0, hue) } ?? false) }
        // a thin ring: on it all round, not just inside it nor just outside it
        if angles.allSatisfy({ ringPoint(at($0, r).0, at($0, r).1, hue) }),
           angles.filter({ ringHue(at($0, r - gap)) || ringHue(at($0, r + gap)) }).count <= 1 { out.append(n.name) }
    }
    // Two people talking over each other are both framed (screenSpeakers sorts out which voice is whose over many looks); more at
    // once is a colour that is not the frame (a violet theme, avatar rooms), which would vote for every voice.
    return out.count <= 2 ? out : []
}

// MARK: folders and subfolders: a subfolder is a path, "Project/Standups"

func folderLeaf(_ f: String) -> String { f.components(separatedBy: "/").last ?? f }
func folderDepth(_ f: String) -> Int { f.components(separatedBy: "/").count - 1 }
/// "Project › Standups", for places that show a folder out of its tree.
func folderPath(_ f: String) -> String { f.components(separatedBy: "/").joined(separator: " \u{203A} ") }

/// The lines left of a subfolder, like the `tree` command: one per level below the top. For each ancestor level, whether a line goes on
/// down past this row (that ancestor has a later sibling: "│"); the last, whether this folder has a later sibling ("├", else "└").
/// `tree` is the folders in tree order.
func treeGuides(_ f: String, in tree: [String]) -> [Bool] {
    func parent(_ x: String) -> String { x.components(separatedBy: "/").dropLast().joined(separator: "/") }
    func hasLater(_ x: String) -> Bool {
        guard let i = tree.firstIndex(of: x) else { return false }
        return tree[(i + 1)...].contains { folderDepth($0) == folderDepth(x) && parent($0) == parent(x) }
    }
    let parts = f.components(separatedBy: "/")
    return parts.count < 2 ? [] : (2...parts.count).map { hasLater(parts[..<$0].joined(separator: "/")) }
}

/// A folder path after `old` is renamed to `new`: `old` itself and its subfolders change, anything else stays.
func renamedFolder(_ f: String, from old: String, to new: String) -> String {
    f == old ? new : f.hasPrefix(old + "/") ? new + f.dropFirst(old.count) : f
}

/// A meeting with these folders is in `folder` if it is in it or in one of its subfolders.
func isIn(_ tags: [String], _ folder: String) -> Bool { tags.contains { $0 == folder || $0.hasPrefix(folder + "/") } }

/// All folders with their parents added ("A/B" brings "A"), sorted as a tree: each parent before its children.
func folderTree(_ names: some Collection<String>) -> [String] {
    var all = Set<String>()
    for n in names {
        let parts = n.components(separatedBy: "/")
        for i in 1...parts.count { all.insert(parts[..<i].joined(separator: "/")) }
    }
    return all.sorted { $0.lowercased().components(separatedBy: "/").lexicographicallyPrecedes($1.lowercased().components(separatedBy: "/")) }
}

/// Which meetings a folder report covers.
enum ReportPeriod: String, CaseIterable {
    case today = "Today", week = "This Week", last7 = "Last 7 Days", month = "This Month", all = "All"

    func contains(_ d: Date, now: Date = Date(), calendar cal: Calendar = .current) -> Bool {
        switch self {
        case .today: cal.isDate(d, inSameDayAs: now)
        case .week: cal.isDate(d, equalTo: now, toGranularity: .weekOfYear)
        case .last7: d > now.addingTimeInterval(-7 * 86400) && d <= now
        case .month: cal.isDate(d, equalTo: now, toGranularity: .month)
        case .all: true
        }
    }
}

/// A progress update over several meetings of one folder, for a period the user picked.
func updatePrompt(template: String) -> String {
    let t = template.trimmingCharacters(in: .whitespacesAndNewlines)
    return """
    You write a progress update over several meetings of one team or project, for the user. You get the meetings oldest first, each with a heading "## <title> (<date>) [id: <id>]", the user's notes and the meeting's summary (or the start of its transcript).
    Always write in English, as terse Markdown: "# Topic" headings, short factual bullets, owners in parentheses, 24-hour time, concrete dates and numbers.
    Start with "# Overview": 3-5 bullets with the main outcomes of the period.
    Then group by topic, not by meeting. For each topic: what happened over the period, what was decided, what changed since the earlier meetings, what is still open or blocked. Mention the date when something happened.
    End with "# Next Steps": the actions still open at the end of the period, "- **Action** (Owner)", with the date they came up.
    Never invent facts. No intro and no closing remarks.
    """ + (t.isEmpty ? "" : "\n\nThe user's template for this folder (follow it where it fits an update):\n\(t)")
}

let askAllPrompt = """
You help the user find things across their past meetings. You get notes and summaries of many meetings, newest first,
each with a heading "## <title> (<date>) [id: <id>]", then a question.
Answer briefly from these meetings only; say so if the answer is not there. When you use a meeting, cite it as a Markdown link [<title>, <date>](/m/<id>).
Reply in the language of the question. Use 24-hour time.
"""

// MARK: live recognition windows (Recorder runs one per speaker)

/// One recognition pass a Windower asks for: the window's audio with up to `ctx` samples of what came before it (context the recognizer
/// hears but whose words are not this window's), and the window's start, in samples of this speaker's stream.
struct Pass {
    let gen: Int; let audio: [Float]; let ctx: Int; let start: Int; let final: Bool
    var voiced = 0  // samples of the window (not its context) voice detection took for speech

    /// The same pass without its context: for when the context threw the recognizer off (see Windower.thin).
    var bare: Pass { Pass(gen: gen, audio: Array(audio[ctx...]), ctx: 0, start: start, final: final, voiced: voiced) }
}

/// Text for a window: the window's start in samples, final or not, and its words timed from the window start.
struct Emit { let start: Int; let final: Bool; let segments: [Segment] }

/// The live transcript of one speaker as windows of audio that are re-recognized as they grow, so words show up fast and get better
/// with context (Parakeet: about half the words right on 2 s pieces, 95% on 15 s). Speech decides where windows start and end (from voice
/// activity detection, 256 ms at a time). Finished sentences are locked once two passes agree and are cut off the window, with the last
/// 2 s kept as context, so text on screen is never rewritten later and the next words are still heard in context. A window ends at a
/// pause; one that would outgrow what the model hears at once (15 s) is cut at a sentence end, else at the widest pause between words.
/// Pure logic: the Recorder feeds audio and runs the passes, Tests/main.swift checks it with a made-up recognizer.
final class Windower {
    let rate = 16000
    var ctxMax = 16000 * 2           // context kept before a window
    var preroll = 16000              // audio before the first speech that belongs to the window (voice detection notices a word late)
    var hard = 240_000               // the most audio the model hears at once (15 s): a pass never gets more, context goes first
    var limit = 240_000 - 4096 * 3   // a window this long (with its context) gets cut
    var updateMin = 16000            // a pass once this much new audio came in...
    var updateMax = 16000 * 5 / 2    // ...at a pause, or at the latest after this much
    var pauseUpdate = 4096           // a pause long enough for a pass
    var pauseFinal = 16000 * 4 / 5   // a pause that ends a window of minFinal or more
    var minFinal = 16000 * 3
    var pauseEnd = 16000 * 2         // a pause that ends any window

    private(set) var buf: [Float] = []  // context + window
    private(set) var ctx = 0, start = 0, active = false  // active: a window is open
    private var clock = 0, quiet = 0, since = 0, gen = 0, inFlight = false, voiced = 0
    private var emitted = Int.min / 2  // where the last word given as final ends (stream sample)
    private var recent: [String] = []  // the last words given as final: a window that started while the last one was ending hears them again
    private var heard: [Segment] = []  // the last text of the open window (from its start): a pass that comes back with far less is a failed one
    private var previous: [String]?  // the sentences of the last pass over this window, to lock only what two passes agree on

    /// Audio of this speaker, in order; `speech` is whether it holds speech. Returns the passes to run, in order.
    func push(_ chunk: [Float], speech: Bool) -> [Pass] {
        clock += chunk.count
        buf += chunk
        guard active else {
            if buf.count > ctxMax + preroll { buf.removeFirst(buf.count - ctxMax - preroll) }
            guard speech else { return [] }
            active = true
            let lead = min(buf.count, preroll + chunk.count)
            ctx = buf.count - lead; start = clock - lead
            quiet = 0; since = lead; previous = nil; voiced = chunk.count
            return []
        }
        since += chunk.count
        if speech { voiced += chunk.count }
        quiet = speech ? 0 : quiet + chunk.count
        if quiet >= pauseEnd || (quiet >= pauseFinal && buf.count - ctx >= minFinal) || buf.count >= limit + 16000 * 2 { return [finish()] }
        if !inFlight, buf.count >= limit || (since >= updateMin && (quiet >= pauseUpdate || since >= updateMax)) {
            since = 0; inFlight = true
            return [pass(final: false)]
        }
        return []
    }

    /// The window as it is, as a final pass (the speaker stopped, the stream had a gap, or the recording ends). Nothing when idle.
    func flush() -> [Pass] { active ? [finish()] : [] }

    /// The window and as much of its context as fits in what the model hears at once.
    private func pass(final: Bool) -> Pass {
        let drop = min(ctx, max(0, buf.count - hard))
        return Pass(gen: gen, audio: Array(buf[drop...]), ctx: ctx - drop, start: start, final: final, voiced: voiced)
    }

    private func finish() -> Pass {
        let p = pass(final: true)
        gen += 1; active = false; inFlight = false; previous = nil
        buf = Array(buf.suffix(ctxMax))
        return p
    }

    /// A pass came back with tokens timed from the start of its audio (nil: it failed). Returns the text to show, in order.
    /// A pass whose own words are too few for the speech in it (under 1.2 a second of speech, from 2 s on): the context before can throw
    /// the recognizer off, as when it was in another language ("Добрий день, колеги." then "Good afternoon..." came back without the
    /// English). The Recorder then tries the pass without its context and keeps whichever heard more.
    func thin(_ p: Pass, _ tokens: [Segment]) -> Bool {
        let seconds = Double(p.voiced) / Double(rate)
        return p.ctx > 0 && seconds >= 2 && Double(wordSpans(mine(p, tokens)).count) < 1.2 * seconds
    }

    /// The words of a pass that are its window's, timed from the window start.
    private func mine(_ p: Pass, _ tokens: [Segment]) -> [Segment] {
        let c = Double(p.ctx) / Double(rate)
        var own: [Segment] = [], keep = p.ctx == 0
        for t in tokens {
            if t.text.hasPrefix(" ") { keep = t.start >= c - 0.08 }
            if keep { own.append((max(0, t.start - c), max(0, t.end - c), t.text)) }
        }
        return own
    }

    /// The context threw this window's pass off (see thin): the window goes on without it, so the next passes do not lose those words again.
    func forgetContext(_ p: Pass) {
        guard p.gen == gen, active, p.start == start, ctx > 0 else { return }
        buf.removeFirst(ctx); ctx = 0
    }

    /// How many of the pass's own words there are (to compare a pass with and without its context).
    func words(_ p: Pass, _ tokens: [Segment]) -> Int { wordSpans(mine(p, tokens)).count }

    func done(_ p: Pass, _ tokens: [Segment]?) -> [Emit] {
        if !p.final && p.gen == gen { inFlight = false }
        guard let tokens else { return [] }
        // The context's words belong to the window before, whole: a word goes with the window it starts in, pieces and punctuation
        // with it (token times move a little from pass to pass, so a piece of the last locked word can land after the edge).
        var own = mine(p, tokens)
        // A window that started while the one before was ending hears its last words again: the words at its start that repeat the
        // last final words, and start before those ended (plus 0.3 s), are that window's.
        let ws = wordSpans(own), soon = Double(emitted - p.start) / Double(rate) + 0.3
        let k = repeatedWords(ws.filter { $0.start < soon }.map(\.word), recent)
        if k > 0 { own.removeFirst(ws[k - 1].tokenEnd) }
        // The recognizer sometimes gives up on a window it heard fine a moment ago (nothing, or the first few words): a pass with less
        // than half the words of the one before on the same window, now longer, is a failed pass. A final one keeps the text before.
        let failed = wordSpans(own).count * 2 < wordSpans(heard).count
        if p.final {
            let before = heard  // passes come back in order: what was heard is this window's
            heard = []
            if failed { own = before }
            guard let last = own.last else { return [] }
            given(own, p.start + Int(last.end * Double(rate)))
            return [Emit(start: p.start, final: true, segments: own)]
        }
        guard p.gen == gen, active, p.start == start else { return [] }  // the window was finished since: its final pass has the text
        if failed { return [] }
        heard = own
        let len = Double(p.audio.count - p.ctx) / Double(rate)
        let now = sentences(own)
        var n = lockableSentences(now, previous: previous, audioEnd: len)
        var cut: (tokens: Int, at: Double)?
        if n > 0 {
            cut = (now[n - 1].tokenEnd, cutTime(now[n - 1]))
        } else if buf.count >= limit {  // too long: lock what there is, agreed or not
            if now.count > 1 {
                n = now.count - 1; cut = (now[n - 1].tokenEnd, cutTime(now[n - 1]))
            } else if let i = forcedCut(own, from: max(0, len - 8), to: len - 1) {
                cut = (i, (own[i - 1].end + own[i].start) / 2)
            } else {
                cut = (own.count, len)
            }
        }
        guard let (k, at) = cut else {
            previous = now.map(\.text)
            return [Emit(start: p.start, final: false, segments: own)]
        }
        heard = own[k...].map { (max(0, $0.start - at), max(0, $0.end - at), $0.text) }
        if k > 0 { given(Array(own[..<k]), p.start + Int(own[k - 1].end * Double(rate))) }
        let samples = min(Int(at * Double(rate)), buf.count - ctx)
        voiced = max(0, voiced - samples)
        let shift = Double(samples) / Double(rate)
        start += samples
        let keep = min(ctxMax, ctx + samples)
        buf.removeFirst(ctx + samples - keep); ctx = keep
        previous = n > 0 ? now[n...].map(\.text) : nil
        let rest: [Segment] = own[k...].map { (max(0, $0.start - shift), max(0, $0.end - shift), $0.text) }
        return [Emit(start: p.start, final: true, segments: Array(own[..<k])), Emit(start: start, final: false, segments: rest)]
    }

    /// Words given as final, ending at stream sample `end`.
    private func given(_ segs: [Segment], _ end: Int) {
        emitted = max(emitted, end)
        recent = Array((recent + wordSpans(segs).map(\.word)).suffix(8))
    }

    /// Just after a sentence's last word, before the next word starts.
    private func cutTime(_ s: Sentence) -> Double { s.next.map { min(s.end + 0.15, (s.end + $0) / 2) } ?? s.end + 0.15 }
}

/// Audio brought to the level the recognizer works best at, a little at a time: around each 32 ms the loudest speech within a quarter
/// second either way goes to about -22 dBFS (at most 30 times louder, never clipping), and the quiet between words never above a
/// quarter of that. Parakeet makes up words or drops them on very quiet audio ("thousands of the same thing" for a quiet "thousands"),
/// also when a quiet person follows a loud one in the same window, and gets them right once they are louder.
func leveled(_ x: [Float], target: Float = 0.08, most: Float = 30, reach: Int = 8) -> [Float] {
    let n = 512
    guard x.count >= n else { return x }
    var f: [Float] = [], peaks: [Float] = []
    var i = 0
    while i < x.count {
        let end = min(i + n, x.count)
        var e: Float = 0, p: Float = 0
        for k in i..<end { e += x[k] * x[k]; p = max(p, abs(x[k])) }
        f.append((e / Float(end - i)).squareRoot()); peaks.append(p); i = end
    }
    let noise = f.sorted()[f.count / 10]
    var g = [Float](repeating: 1, count: f.count)
    for j in f.indices {
        let lo = max(0, j - reach), hi = min(f.count - 1, j + reach)
        var env: Float = 0, peak: Float = 0
        for k in lo...hi { env = max(env, f[k]); peak = max(peak, peaks[k]) }
        g[j] = min(most, target / max(env, 1e-5), 0.99 / max(peak, 1e-9), target / 4 / max(noise, 1e-6))
    }
    // smoothed over five frames, then from frame to frame sample by sample
    let s = g.indices.map { j -> Float in
        let lo = max(0, j - 2), hi = min(g.count - 1, j + 2)
        return g[lo...hi].reduce(0, +) / Float(hi - lo + 1)
    }
    var out = x
    for k in x.indices {
        let pos = (Float(k) - Float(n) / 2) / Float(n)
        let j = max(0, min(s.count - 1, Int(pos.rounded(.down))))
        let t = max(0, min(1, pos - Float(j)))
        let gain = j + 1 < s.count ? s[j] * (1 - t) + s[j + 1] * t : s[j]
        out[k] = max(-1, min(1, x[k] * gain))
    }
    return out
}

/// Voice detection misses quiet speech (a far-off mic, a quiet call, a quiet person right after a loud one: -50 dB and below) that the
/// recognizer still gets right, so it hears each 256 ms piece at one level, up to 20 times louder; what is not above the room's own
/// noise (followed quickly down, slowly up) stays quiet.
struct VoiceLevel {
    var most: Float = 20  // the microphone has its own gain control (voice processing): less there
    private(set) var floor: Float = 0.001

    /// The piece as voice detection should hear it, and its loudness (RMS) as it came.
    mutating func adjust(_ x: [Float]) -> (heard: [Float], rms: Float) {
        let rms = (x.reduce(0) { $0 + $1 * $1 } / Float(max(1, x.count))).squareRoot()
        floor = rms < floor ? 0.9 * floor + 0.1 * rms : min(floor * 1.01, 0.05)
        let gain = min(most, 0.05 / max(rms, 3 * floor, 0.0005))
        return (abs(gain - 1) > 0.05 ? x.map { $0 * gain } : x, rms)
    }
}

/// How loud the speech in some audio is: the RMS of its loudest tenth of 32 ms frames (0 for less than a frame).
func speechLevel(_ x: [Float]) -> Float {
    let n = 512
    guard x.count >= n else { return 0 }
    var frames: [Float] = []
    frames.reserveCapacity(x.count / n)
    var i = 0
    while i + n <= x.count {
        var e: Float = 0
        for k in i..<(i + n) { e += x[k] * x[k] }
        frames.append((e / Float(n)).squareRoot()); i += n
    }
    frames.sort()
    return frames[min(frames.count - 1, frames.count * 9 / 10)]
}

/// The words of recognizer tokens, lowercased without punctuation, with when each starts and the index after its last token.
func wordSpans(_ tokens: [Segment]) -> [(word: String, start: Double, tokenEnd: Int)] {
    var out: [(word: String, start: Double, tokenEnd: Int)] = []
    for (i, t) in tokens.enumerated() {
        let core = t.text.lowercased().filter { $0.isLetter || $0.isNumber }
        if t.text.hasPrefix(" ") || out.isEmpty { out.append((core, t.start, i + 1)) } else { out[out.count - 1].word += core; out[out.count - 1].tokenEnd = i + 1 }
    }
    return out
}

/// How many of `words` (the start of a window) repeat the end of `recent`, most first.
func repeatedWords(_ words: [String], _ recent: [String]) -> Int {
    for k in stride(from: min(words.count, recent.count), to: 0, by: -1) where Array(words.prefix(k)) == Array(recent.suffix(k)) { return k }
    return 0
}

/// Wall time of the samples of one audio stream: anchors where the stream started or jumped (a gap while nothing played, a clock that
/// drifted), samples counted from the last one before. Timing comes from the audio's own timestamps, not from when buffers arrive.
struct ClockMap {
    var rate = 16000.0
    private(set) var anchors: [(sample: Int, ms: Double)] = []

    /// Samples from `sample` on started at wall time `ms`. Adds an anchor only when that is more than `tolerance` ms off the time the
    /// last anchor gives; true when the stream jumped ahead (a gap).
    @discardableResult mutating func mark(sample: Int, ms: Double, tolerance: Double = 300) -> Bool {
        guard anchors.last != nil else { anchors.append((sample, ms)); return false }
        let off = ms - self.ms(sample)
        guard abs(off) > tolerance else { return false }
        while let last = anchors.last, last.sample >= sample { anchors.removeLast() }  // kept in sample order
        anchors.append((sample, ms))
        return off > 0
    }

    /// Wall time (epoch ms) of a sample.
    func ms(_ sample: Int) -> Double {
        guard !anchors.isEmpty else { return 0 }
        let i = max(0, firstIndex(anchors.count) { anchors[$0].sample > sample } - 1)
        return anchors[i].ms + Double(sample - anchors[i].sample) * 1000 / rate
    }

    /// The sample at a wall time, from the last anchor at or before it.
    func sample(_ ms: Double) -> Int {
        guard !anchors.isEmpty else { return 0 }
        let i = max(0, (anchors.lastIndex { $0.ms <= ms } ?? 0))
        return anchors[i].sample + Int((ms - anchors[i].ms) * rate / 1000)
    }
}

/// The other side's speech kept for telling the voices apart after the call, in memory only: 16-bit, only the stretches around speech
/// (from 768 ms before to a second after), each with its wall time. Stops taking more at `cap` samples (2 hours) and says so.
struct Tape {
    var cap = 16000 * 3600 * 2
    private(set) var pcm: [Int16] = []
    private(set) var clock = ClockMap()
    private(set) var full = false
    private var held: [(x: [Float], ms: Double)] = []  // the last quiet chunks, the onset of what may come (voice detection is a little late)
    private var after = 0  // quiet chunks still kept after speech

    var seconds: Double { Double(pcm.count) / 16000 }

    /// The next chunk of this speaker's stream (`ms`: its wall time), and whether it holds speech.
    mutating func add(_ x: [Float], ms: Double, speech: Bool) {
        if speech {
            for h in held { append(h.x, h.ms) }
            held = []; after = 4
            append(x, ms)
        } else if after > 0 {
            after -= 1; append(x, ms)
        } else {
            held = Array((held + [(x, ms)]).suffix(3))
        }
    }

    private mutating func append(_ x: [Float], _ ms: Double) {
        guard pcm.count + x.count <= cap else { full = true; return }
        clock.mark(sample: pcm.count, ms: ms, tolerance: 20)
        pcm += x.map { Int16(max(-1, min(1, $0)) * 32767) }
    }

    var floats: [Float] { pcm.map { Float($0) / 32767 } }
}

/// Whether a piece of the microphone is the speakers' sound coming back: it follows the system audio closely at some delay, and the
/// system audio is at least as loud (an echo is quieter than what made it). Faint echo counts too: the levelling for voice detection and
/// the recognizer would bring it up into made-up words. `ref` is the system audio from `maxLag` samples before the mic piece to its
/// end; checked at half the rate, every `step` samples of delay.
func echoLike(_ mic: [Float], _ ref: [Float], maxLag: Int, step: Int = 32) -> Bool {
    guard mic.count >= 64, ref.count >= mic.count + maxLag else { return false }
    func energy(_ x: ArraySlice<Float>) -> Float { var e: Float = 0; var i = x.startIndex; while i < x.endIndex { e += x[i] * x[i]; i += 2 }; return e }
    let n = Float(mic.count / 2)
    let em = energy(mic[...])
    let micRms = (em / n).squareRoot()
    guard micRms >= 0.0005 else { return false }
    var best: Float = 0
    for lag in stride(from: 0, through: maxLag, by: step) {
        let lo = maxLag - lag, seg = ref[lo..<(lo + mic.count)]
        let er = energy(seg)
        guard (er / n).squareRoot() >= max(0.002, micRms * 0.8) else { continue }
        var dot: Float = 0, i = 0
        while i < mic.count { dot += mic[i] * seg[lo + i]; i += 2 }
        best = max(best, dot / (em * er).squareRoot())
    }
    return best >= 0.75
}

// MARK: after a call: the other side's voices told apart again over the whole call

/// Which live voice each voice told apart after the call is: the one most of its live lines had. Live lines the call window named count too
/// ("@Oleg"). A voice with too few lines, or no clear winner, stays new.
func carryVoices(live: [Line], turns: [Turn]) -> [String: String] {
    var votes: [String: [String: Int]] = [:]
    for l in live where l.src == "sys" {
        guard let spk = l.spk, let t = turns.first(where: { $0.start <= l.t + 300 && l.t + 300 < $0.end }) else { continue }
        votes[t.spk, default: [:]][spk, default: 0] += 1
    }
    return votes.compactMapValues { v in
        let total = v.values.reduce(0, +)
        guard let top = v.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }), top.value >= 2, top.value * 10 >= total * 6 else { return nil }
        return top.key
    }
}

/// A call with one other person on the invite and one voice on the other side: that voice is that person.
func oneOnOne(invited: [String], voices: [String]) -> [String: String] {
    invited.count == 1 && voices.count == 1 ? [voices[0]: invited[0]] : [:]
}

// MARK: which app a process holding the microphone is

/// Apps that take the microphone without being a call: dictation, recorders, assistants, Waffle-like tools.
let notCallApps: Set<String> = [
    "com.superduper.superwhisper", "com.prakashjoshipax.VoiceInk", "com.electron.wispr-flow", "com.goodsnooze.MacWhisper", "com.kitlangton.Hex",
    "com.raycast.macos", "com.loom.desktop", "com.obsproject.obs-studio", "com.apple.QuickTimePlayerX", "com.apple.VoiceMemos",
    "com.openai.chat", "com.anthropic.claudefordesktop", "com.apple.dt.Xcode", "com.getcleanshot.app", "com.getcleanshot.app-setapp",
    "com.rogueamoeba.audiohijack", "com.descript.beachcube", "com.aqua.voice", "com.willowvoice.app", "com.spokenly.app",
    "com.screenstudio.app", "io.github.oufinx.waffle",
]

/// The name to show for a process holding the microphone, or nil when it is not a call: macOS itself and the apps above. FaceTime calls
/// run in avconferenced and phone calls in callservicesd; Meet or Teams in Safari in WebKit's GPU process; a browser's tab in a helper
/// app inside the browser (its outermost .app in `path`).
func callAppName(bundle: String, path: String, name: String?) -> String? {
    if notCallApps.contains(bundle) || notCallApps.contains(where: { bundle.hasPrefix($0 + ".") }) { return nil }
    switch bundle {
    case "com.apple.FaceTime", "com.apple.avconferenced": return "FaceTime"
    case "com.apple.TelephonyUtilities", "com.apple.telephonyutilities.callservicesd", "com.apple.callservicesd": return "Phone"
    case "com.apple.WebKit.GPU", "com.apple.WebKit.WebContent": return "Safari"
    default: break
    }
    if bundle.hasPrefix("com.apple.") { return nil }
    if let r = path.range(of: ".app/") {
        let app = path[..<r.lowerBound].split(separator: "/").last.map(String.init)
        if let app, !app.isEmpty { return app }
    }
    return name.flatMap { $0.isEmpty ? nil : $0 } ?? (bundle.isEmpty ? nil : bundle)
}
