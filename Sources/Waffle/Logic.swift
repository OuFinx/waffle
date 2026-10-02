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
private let junk = regex(#"субтитр|dimatorzok|amara\.org|продолжение следует|дякую за перегляд|thanks for watching|^\W*(\[.*\]|\(.*\)|thank you\.?)\W*$|^\W+$"#, .caseInsensitive)
private let sentence = regex(#"\S.*?(?:[.!?…](?=\s|$)|$)"#, .dotMatchesLineSeparators)
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
    return all(sentence, text).compactMap { m in
        let piece = ns.substring(with: m.range).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let at = m.range.location
        let sp = spans.first { $0.a <= at && at < $0.b } ?? last
        let off = Int((sp.start + (sp.end - sp.start) * Double(at - sp.a) / Double(max(sp.b - sp.a, 1))) * 1000)
        return piece.isEmpty || junk.firstMatch(in: piece, range: NSRange(location: 0, length: (piece as NSString).length)) != nil ? nil : (off, piece)
    }
}

func words(_ t: String) -> [String] {
    let lower = t.lowercased(), ns = lower as NSString
    return all(wordRe, lower).map { ns.substring(with: $0.range) }
}

/// On speakers the mic also hears the other side: drop "Me" lines whose words mostly repeat a "Them" line from the same moment.
func dropEcho(_ lines: [Line], windowMs: Int = 30000) -> [Line] {
    let them = lines.filter { $0.src == "sys" }.map { ($0.t, Set(words($0.text))) }
    return lines.filter { l in
        guard l.src == "mic" else { return true }
        let mine = words(l.text)
        guard !mine.isEmpty else { return true }
        return !them.contains { abs($0.0 - l.t) < windowMs && Double(mine.filter($0.1.contains).count) / Double(mine.count) >= 0.6 }
    }
}

/// A new recognition pass over one speaker's window: its lines replace the ones from the previous pass of the same window.
func replaceWindow(_ lines: [Line], src: String, w: Int, part: Int, final: Bool, segments: [Segment], echoMs: Int = 30000) -> [Line] {
    let fresh = splitSentences(segments).map { Line(t: w + $0.0, src: src, text: $0.1, part: part, final: final, w: w) }
    let all = (lines.filter { !($0.w == w && $0.src == src) } + fresh).sorted { $0.t < $1.t }
    // Every pass so far left the transcript free of echoes, so only lines near the new ones can be echoes now: a "Me" line within
    // echoMs of a new line, checked against "Them" lines within echoMs of it. The rest of a long meeting is not looked at again.
    guard let from = fresh.map(\.t).min() else { return all }
    let cut = firstIndex(all.count) { all[$0].t >= from - 2 * echoMs }
    return Array(all[..<cut]) + dropEcho(Array(all[cut...]), windowMs: echoMs)
}

/// Sentences of one recognition pass over recognizer tokens: text, index after its last token, end time, and when the next token starts.
func sentences(_ tokens: [Segment]) -> [(text: String, tokenEnd: Int, end: Double, next: Double?)] {
    var out: [(text: String, tokenEnd: Int, end: Double, next: Double?)] = [], text = ""
    for (i, t) in tokens.enumerated() {
        text += t.text
        let next = i + 1 < tokens.count ? tokens[i + 1] : nil
        let closes = t.text.trimmingCharacters(in: .whitespaces).last.map { ".!?…".contains($0) } ?? false
        if (closes && (next == nil || next!.text.hasPrefix(" "))) || next == nil {
            let s = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if !s.isEmpty { out.append((s, i + 1, t.end, next?.start)) }
            text = ""
        }
    }
    return out
}

/// How many leading sentences of this pass can be locked for good: another sentence already follows each, and each ends at least
/// `margin` seconds before the audio does. Locked text is never re-transcribed, so a later change of language (or a worse guess on a
/// longer window) can not rewrite it.
func lockableSentences(_ now: [(text: String, tokenEnd: Int, end: Double, next: Double?)], audioEnd: Double, margin: Double = 0.8) -> Int {
    var n = 0
    while n < now.count - 1, now[n].end <= audioEnd - margin { n += 1 }
    return n
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
Speaker "Me" is the user; every other label (a name, "Speaker 2", "Them") is someone else on the call; "Them" can be several people. If the input lists the people seen in the call window, they are most likely the people in the call. The transcript is machine-made and may have recognition errors.
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
    let cut = raw.components(separatedBy: CharacterSet(charactersIn: ",(|[\n\u{2022}")).first ?? raw
    let words = cut.split(whereSeparator: \.isWhitespace).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".:;!?\"")) }.filter { !$0.isEmpty }
    guard (minWords...4).contains(words.count), words.joined().count <= 40 else { return nil }
    for w in words {
        guard let f = w.first, f.isUppercase, w.allSatisfy({ $0.isLetter || $0 == "-" || $0 == "'" || $0 == "\u{2019}" }), !appWords.contains(w.lowercased()) else { return nil }
    }
    return words.joined(separator: " ")
}

private let talkingFirst = regex(#"^\s*(?:talking|speaking|говорить|говорит|розмовляє)\s*:\s*(.+)$"#, .caseInsensitive)
private let talkingAfter = regex(#"^(.+?)(?:\s+is|\s*,|\s*\(|\s+-)?\s*(?:is\s+)?\b(?:speaking|talking|говорить|говорит|розмовляє)\b"#, .caseInsensitive)

/// Who the call window says is talking, from its labels or text: "Talking: Oleg Petrenko" (Zoom), "Oleg Petrenko is speaking",
/// "Oleg Petrenko, speaking", "Oleg Petrenko (speaking)", also in Ukrainian. One-word names count here.
func speakingNames(_ texts: [String]) -> [String] {
    var out: [String] = []
    for t in texts {
        let ns = t as NSString, r = NSRange(location: 0, length: ns.length)
        guard t.count <= 120, t.range(of: "not speaking", options: .caseInsensitive) == nil,
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
    let taken = Dictionary(grouping: out.values) { $0 }
    return out.filter { taken[$0.value]?.count == 1 }
}

/// "Them" lines that no diarized voice covers get the person the call window showed as the only one talking around then (from 1 s
/// before the line to 4 s after), as the voice "@Name". `talking` is in time order.
func labelFromScreen(_ lines: [Line], _ talking: [(t: Int, name: String)]) -> [Line] {
    guard !talking.isEmpty else { return lines }
    var out = lines
    for i in out.indices where out[i].src == "sys" && (out[i].spk == nil || out[i].spk!.hasPrefix("@")) {
        let t = out[i].t
        var j = firstIndex(talking.count) { talking[$0].t >= t - 1000 }, near = Set<String>()
        while j < talking.count, talking[j].t <= t + 4000 { near.insert(talking[j].name); j += 1 }
        if near.count == 1 { out[i].spk = "@" + near.first! }
    }
    return out
}

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
