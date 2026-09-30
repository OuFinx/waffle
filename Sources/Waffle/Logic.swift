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
func labelSpeakers(_ lines: [Line], _ turns: [Turn]) -> [Line] {
    guard !turns.isEmpty else { return lines }
    let sys = lines.indices.filter { lines[$0].src == "sys" }
    var out = lines
    for (k, i) in sys.enumerated() {
        let s = lines[i].t, e = k + 1 < sys.count ? max(min(lines[sys[k + 1]].t, s + 10000), s + 500) : s + 4000
        var overlap: [String: Int] = [:]
        for t in turns where t.end > s && t.start < e { overlap[t.spk, default: 0] += min(t.end, e) - max(t.start, s) }
        if let top = overlap.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }) { out[i].spk = top.key }
    }
    return out
}

/// What each voice of "Them" is called: the name the user gave it, else "Speaker N" in order of first appearance. A single unnamed
/// voice is just "Them".
func speakerNames(_ lines: [Line], names: [String: String]) -> [String: String] {
    var order: [String] = []
    for l in lines where l.src == "sys" { if let s = l.spk, !order.contains(s) { order.append(s) } }
    var out: [String: String] = [:]
    for (i, s) in order.enumerated() { out[s] = names[s] ?? (order.count == 1 ? "Them" : "Speaker \(i + 1)") }
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
func replaceWindow(_ lines: [Line], src: String, w: Int, part: Int, final: Bool, segments: [Segment]) -> [Line] {
    let fresh = splitSentences(segments).map { Line(t: w + $0.0, src: src, text: $0.1, part: part, final: final, w: w) }
    return dropEcho((lines.filter { !($0.w == w && $0.src == src) } + fresh).sorted { $0.t < $1.t })
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
Speaker "Me" is the user (their microphone). Every other label is someone else on the call: a name, "Speaker 2" (a voice told apart by sound, name unknown), or "Them" (everyone else together; tell people apart by names and context when possible).
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
line 3: "SPEAKERS: <for transcript labels like "Speaker 2" whose real name is clear from the conversation (someone addresses them by name, they introduce themselves): "Speaker 2 = Oleg", comma-separated; empty if none is clear; never guess>"
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
Speaker "Me" is the user; every other label (a name, "Speaker 2", "Them") is someone else on the call. The transcript is machine-made and may have recognition errors.
Answer briefly and only from the transcript; say so if it is not there. Reply in the language of the question.
"""

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
