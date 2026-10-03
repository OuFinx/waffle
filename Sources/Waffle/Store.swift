// Meetings on disk, same layout the earlier Python version used, so existing meetings keep working:
// <data>/meetings/<YYYY-MM-DD_HH-MM-SS>/ transcript.jsonl, transcript.md, notes.md, chat.jsonl, summary-N.en.md, meta.json
// <data>/settings.json, <data>/templates.json. <data> is ~/Library/Application Support/Waffle, or $WAFFLE_DATA.
import Foundation

let dataDir = URL(fileURLWithPath: ((ProcessInfo.processInfo.environment["WAFFLE_DATA"] ?? "~/Library/Application Support/Waffle") as NSString).expandingTildeInPath)
let meetingsDir = dataDir.appendingPathComponent("meetings")
let askAllBudget = 150_000  // characters of meeting notes sent to Claude when asking across meetings

struct Chat: Codable, Hashable { var t: Int; var q: String; var a: String }

struct SearchHit: Identifiable, Hashable { let id: String; let snippet: String }

/// A report over some meetings of a folder. id: when it was written (the meeting id format).
struct Report: Codable, Identifiable, Hashable { let id: String; let folder: String; let title: String; let text: String }

enum Store {
    private static let fm = FileManager.default
    private static let lock = NSLock()  // meta, settings and templates are read-modify-write
    private static let idPattern = try! NSRegularExpression(pattern: #"^\d{4}-\d\d-\d\d_\d\d-\d\d-\d\d$"#)

    static func dir(_ id: String) -> URL { meetingsDir.appendingPathComponent(id) }

    /// Where versions before 0.4 kept their speech model (whisper.cpp's): removed once the new models are there.
    static var oldModels: URL { dataDir.appendingPathComponent("models") }

    /// Newest first.
    static func ids() -> [String] {
        ((try? fm.contentsOfDirectory(atPath: meetingsDir.path)) ?? [])
            .filter { idPattern.firstMatch(in: $0, range: NSRange(location: 0, length: ($0 as NSString).length)) != nil }
            .sorted(by: >)
    }

    static func create() -> String {
        let id = idFormat.string(from: Date())
        try? fm.createDirectory(at: dir(id), withIntermediateDirectories: true)
        return id
    }

    static func text(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
    static func write(_ s: String, _ url: URL) { try? s.write(to: url, atomically: true, encoding: .utf8) }
    private static func json(_ url: URL) -> [String: Any] { (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any] ?? [:] }
    private static func writeJSON(_ obj: Any, _ url: URL) {
        if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) { try? d.write(to: url, options: .atomic) }
    }

    // MARK: meta: {"title": {"en": ...}, "tags": [...], "recording": bool}

    static func meta(_ id: String) -> [String: Any] { json(dir(id).appendingPathComponent("meta.json")) }
    static func updateMeta(_ id: String, _ fields: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        writeJSON(meta(id).merging(fields) { $1 }, dir(id).appendingPathComponent("meta.json"))
    }
    static func title(_ id: String) -> String? { ((meta(id)["title"] as? [String: Any])?["en"] as? String).flatMap { $0.isEmpty ? nil : $0 } }
    static func tags(_ id: String) -> [String] { meta(id)["tags"] as? [String] ?? [] }
    static func setTags(_ id: String, _ tags: [String]) {
        updateMeta(id, ["tags": Set(tags.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }).sorted { $0.lowercased() < $1.lowercased() }])
    }
    /// Stays true if the app died mid-meeting: that is how an interrupted meeting is recognised.
    static func recordingFlag(_ id: String) -> Bool { meta(id)["recording"] as? Bool ?? false }

    // MARK: transcript, notes, summaries, chat

    static func lines(_ id: String) -> [Line] {
        text(dir(id).appendingPathComponent("transcript.jsonl")).split(separator: "\n").compactMap { try? JSONDecoder().decode(Line.self, from: Data($0.utf8)) }
    }
    static func saveLines(_ id: String, _ lines: [Line]) {
        writer.sync { soon = nil; writeLines(id, lines) }  // after any write still queued, so the file ends up with these
    }

    /// Save while recording, off the main queue: the transcript changes several times a second, and a long one is a big file. Saves
    /// coming faster than they are written count once (the newest).
    static func saveLinesSoon(_ id: String, _ lines: [Line]) {
        writer.async {
            let first = soon == nil
            soon = (id, lines)
            guard first else { return }
            writer.asyncAfter(deadline: .now() + 1) { if let x = soon { soon = nil; writeLines(x.0, x.1) } }
        }
    }

    private static let writer = DispatchQueue(label: "transcript writer", qos: .utility)
    nonisolated(unsafe) private static var soon: (String, [Line])?  // on the writer queue only

    private static func writeLines(_ id: String, _ lines: [Line]) {
        let enc = JSONEncoder()
        enc.outputFormatting = .withoutEscapingSlashes
        write(lines.compactMap { try? String(decoding: enc.encode($0), as: UTF8.self) }.map { $0 + "\n" }.joined(), dir(id).appendingPathComponent("transcript.jsonl"))
    }
    static func notes(_ id: String) -> String { text(dir(id).appendingPathComponent("notes.md")) }
    static func saveNotes(_ id: String, _ s: String) { write(s, dir(id).appendingPathComponent("notes.md")) }

    private static func summaryCount(_ id: String) -> Int {
        ((try? fm.contentsOfDirectory(atPath: dir(id).path)) ?? []).filter { $0.hasPrefix("summary-") && $0.hasSuffix(".en.md") }.count
    }
    /// The newest summary; older ones stay on disk.
    static func summary(_ id: String) -> String? {
        let n = summaryCount(id)
        let s = n > 0 ? text(dir(id).appendingPathComponent("summary-\(n).en.md")).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return s.isEmpty ? nil : s
    }
    static func addSummary(_ id: String, _ s: String) { write(s + "\n", dir(id).appendingPathComponent("summary-\(summaryCount(id) + 1).en.md")) }

    static func chat(_ id: String) -> [Chat] {
        text(dir(id).appendingPathComponent("chat.jsonl")).split(separator: "\n").compactMap { try? JSONDecoder().decode(Chat.self, from: Data($0.utf8)) }
    }
    static func appendChat(_ id: String, _ c: Chat) {
        let url = dir(id).appendingPathComponent("chat.jsonl")
        let row = (try? String(decoding: JSONEncoder().encode(c), as: UTF8.self)) ?? ""
        write(text(url) + row + "\n", url)
    }

    // MARK: settings.json {"claude_model": "sonnet", "summary_prompt": ""} and templates.json {folder: template}

    static var settings: [String: Any] { json(dataDir.appendingPathComponent("settings.json")) }
    static var claudeModel: String { settings["claude_model"] as? String ?? "sonnet" }
    // MARK: templates.json: the summary template library (see TemplateLibrary)

    private static var templatesURL: URL { dataDir.appendingPathComponent("templates.json") }

    /// The library. A templates.json from before (folder templates as {folder: text}) and the old custom summary instructions in
    /// settings.json are moved into it once; the old file is kept as templates-old.json.
    static var library: TemplateLibrary {
        lock.lock(); defer { lock.unlock() }
        if let d = try? Data(contentsOf: templatesURL), let lib = try? JSONDecoder().decode(TemplateLibrary.self, from: d) { return lib }
        let lib = migrateTemplates(json(templatesURL), customPrompt: settings["summary_prompt"] as? String ?? "")
        if fm.fileExists(atPath: templatesURL.path) { try? fm.copyItem(at: templatesURL, to: dataDir.appendingPathComponent("templates-old.json")) }
        saveLibraryLocked(lib)
        return lib
    }

    static func saveLibrary(_ lib: TemplateLibrary) {
        lock.lock(); defer { lock.unlock() }
        saveLibraryLocked(lib)
    }

    private static func saveLibraryLocked(_ lib: TemplateLibrary) {
        try? fm.createDirectory(at: dataDir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let d = try? enc.encode(lib) { try? d.write(to: templatesURL, options: .atomic) }
    }

    // MARK: folders.json {folder: {"emoji": "🚀"}}: folders made with + (they exist before any meeting is in them) and every folder's emoji

    static var folderMeta: [String: [String: String]] { json(dataDir.appendingPathComponent("folders.json")) as? [String: [String: String]] ?? [:] }
    /// Keys: "emoji", "period" (the default report period).
    static func setFolderField(_ folder: String, _ key: String, _ value: String?) {
        lock.lock(); defer { lock.unlock() }
        var m = folderMeta
        m[folder, default: [:]][key] = value
        writeJSON(m, dataDir.appendingPathComponent("folders.json"))
    }
    static func setFolderEmoji(_ folder: String, _ emoji: String) { setFolderField(folder, "emoji", emoji) }

    /// A folder and its subfolders out of folders.json, and their reports to the Trash.
    static func removeFolder(_ folder: String) {
        lock.lock()
        writeJSON(folderMeta.filter { !isIn([$0.key], folder) }, dataDir.appendingPathComponent("folders.json"))
        lock.unlock()
        for r in allReports() where isIn([r.folder], folder) { deleteReport(r.id) }
    }

    /// A folder and its subfolders under a new name in folders.json and in their reports.
    static func renameFolder(_ old: String, to new: String) {
        lock.lock()
        var m: [String: [String: String]] = [:]
        for (k, v) in folderMeta { m[renamedFolder(k, from: old, to: new), default: [:]].merge(v) { $1 } }
        writeJSON(m, dataDir.appendingPathComponent("folders.json"))
        lock.unlock()
        for r in allReports() where isIn([r.folder], old) {
            addReport(Report(id: r.id, folder: renamedFolder(r.folder, from: old, to: new), title: r.title, text: r.text))
        }
    }

    // MARK: reports/<id>.json: every report written for a folder, id = when it was written

    private static var reportsDir: URL { dataDir.appendingPathComponent("reports") }

    /// A folder's reports, newest first.
    static func reports(_ folder: String) -> [Report] { allReports().filter { $0.folder == folder } }
    /// Every report, newest first.
    static func allReports() -> [Report] {
        ((try? fm.contentsOfDirectory(atPath: reportsDir.path)) ?? []).filter { $0.hasSuffix(".json") }.sorted(by: >)
            .compactMap { try? JSONDecoder().decode(Report.self, from: Data(contentsOf: reportsDir.appendingPathComponent($0))) }
    }
    static func report(_ id: String) -> Report? { try? JSONDecoder().decode(Report.self, from: Data(contentsOf: reportsDir.appendingPathComponent("\(id).json"))) }
    @discardableResult static func addReport(_ r: Report) -> Bool {
        try? fm.createDirectory(at: reportsDir, withIntermediateDirectories: true)
        guard let d = try? JSONEncoder().encode(r) else { return false }
        return (try? d.write(to: reportsDir.appendingPathComponent("\(r.id).json"), options: .atomic)) != nil
    }
    static func deleteReport(_ id: String) { try? fm.trashItem(at: reportsDir.appendingPathComponent("\(id).json"), resultingItemURL: nil) }

    /// Before the history, folders.json kept only the latest report ("update", "updateLabel"): move it into reports/ once.
    static func migrateLatestReports() {
        let url = dataDir.appendingPathComponent("folders.json")
        let written = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        for (folder, m) in folderMeta {
            guard let text = m["update"] else { continue }
            let title = m["updateLabel"].map { $0.components(separatedBy: ". Written ")[0] } ?? "Report"
            var at = written  // one id per report, even when several folders move at once
            while report(idFormat.string(from: at)) != nil { at += 1 }
            guard addReport(Report(id: idFormat.string(from: at), folder: folder, title: title, text: text)) else { continue }
            setFolderField(folder, "update", nil); setFolderField(folder, "updateLabel", nil)
        }
    }

    // MARK: what Claude gets

    static func allFolders() -> Set<String> { Set(ids().flatMap(tags)).union(library.folders.keys).union(folderMeta.keys) }

    /// The folders there are and the meeting's own, so the summary can file the meeting.
    static func foldersText(_ id: String) -> String {
        let rows = allFolders().sorted { $0.lowercased() < $1.lowercased() }.map { "- \($0)" }
        let mine = tags(id)
        return "# Folders\nAlready in: \(mine.isEmpty ? "none" : mine.joined(separator: ", "))\nExisting folders:\n" + (rows.isEmpty ? "(none)" : rows.joined(separator: "\n"))
    }

    /// Notes, the people seen in the call window and the transcript of a meeting, as Claude gets them.
    static func context(_ id: String, lines: [Line], names: [String: String]? = nil, people: [String]? = nil) -> String {
        let notes = self.notes(id), people = Set(self.people(id)).union(people ?? []).sorted()
        let event = meta(id)["calendar"] as? [String: Any], invited = event?["invited"] as? [String] ?? [], title = event?["title"] as? String ?? ""
        return "# My notes\n\(notes.isEmpty ? "(empty)" : notes)\n\n"
            + (event == nil ? "" : "# Calendar event\nTitle: \(title)\nInvited: \(invited.isEmpty ? "(nobody listed)" : invited.joined(separator: ", "))\n\n")
            + (people.isEmpty ? "" : "# People seen in the call window\n\(people.joined(separator: ", "))\n\n")
            + "# Transcript\n\(lines.isEmpty ? "(empty)" : transcriptText(lines, names: names ?? speakers(id)))"
    }

    /// Names the user gave to the voices of "Them": {"1-2": "Oleg"}.
    static func speakers(_ id: String) -> [String: String] { meta(id)["speakers"] as? [String: String] ?? [:] }
    static func nameSpeaker(_ id: String, _ spk: String, _ name: String) {
        var s = speakers(id)
        let n = name.trimmingCharacters(in: .whitespaces)
        s[spk] = n.isEmpty ? nil : n
        updateMeta(id, ["speakers": s])
    }

    /// The people the call window (Zoom, Teams) showed during the meeting, see ScreenNames.
    static func people(_ id: String) -> [String] { meta(id)["people"] as? [String] ?? [] }

    /// Newest first: each meeting's summary (or the start of its transcript) and notes, up to the budget.
    static func askAllContext(folder: String?) -> String {
        meetingsContext(ids().filter { folder == nil || isIn(tags($0), folder!) })  // a folder's subfolders count too
    }

    /// These meetings in this order: heading with title, date and id, the user's notes, the summary (or the start of the transcript).
    static func meetingsContext(_ ids: [String]) -> String {
        var parts: [String] = [], size = 0
        for id in ids {
            let body = summary(id) ?? String(transcriptText(lines(id), names: speakers(id)).prefix(4000))
            let notes = self.notes(id).trimmingCharacters(in: .whitespacesAndNewlines)
            let part = "## \(title(id) ?? "Untitled") (\(id.prefix(10)) \(id.dropFirst(11).prefix(5).replacingOccurrences(of: "-", with: ":"))) [id: \(id)]\n"
                + (notes.isEmpty ? "" : "User notes:\n\(notes)\n") + (body.isEmpty ? "(empty)" : body)
            if size + part.count > askAllBudget { break }
            parts.append(part); size += part.count
        }
        return parts.isEmpty ? "(no meetings)" : parts.joined(separator: "\n\n")
    }

    /// Case-insensitive substring search over titles, folders, notes, summaries and transcripts; the first hit becomes the snippet.
    static func search(_ query: String, limit: Int = 50) -> [SearchHit] {
        let q = query.trimmingCharacters(in: .whitespaces)
        var out: [SearchHit] = []
        for id in ids() {
            let texts = [title(id)].compactMap { $0 } + tags(id) + [notes(id), summary(id) ?? ""] + lines(id).map(\.text)
            for t in texts {
                guard let r = t.range(of: q, options: .caseInsensitive) else { continue }
                let from = t.index(r.lowerBound, offsetBy: -60, limitedBy: t.startIndex) ?? t.startIndex
                let to = t.index(r.upperBound, offsetBy: 80, limitedBy: t.endIndex) ?? t.endIndex
                let snippet = (from > t.startIndex ? "..." : "") + t[from..<to].replacingOccurrences(of: "\n", with: " ") + (to < t.endIndex ? "..." : "")
                out.append(SearchHit(id: id, snippet: snippet))
                break
            }
            if out.count >= limit { break }
        }
        return out
    }
}
