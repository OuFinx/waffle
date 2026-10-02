// App state: the list of meetings, what is selected, and the one meeting that is recording or being summarised right now.
// Everything else is read from disk when shown.
import AppKit
import Combine

enum Status { case idle, recording, finalizing, summarizing, done }

enum Scope: Hashable {
    case all, today, week, unfiled, folder(String)

    /// Library lists: name, symbol, which meetings. Unfiled meetings are "No Folder", at the top of the Folders section.
    static let library: [(scope: Scope, name: String, symbol: String)] = [
        (.all, "All Meetings", "tray"), (.today, "Today", "sun.max"), (.week, "This Week", "calendar"),
    ]

    var name: String {
        if case let .folder(f) = self { return f }
        if self == .unfiled { return "No Folder" }
        return Scope.library.first { $0.scope == self }?.name ?? ""
    }

    func contains(_ m: MeetingRow) -> Bool {
        switch self {
        case .all: true
        case .today: Calendar.current.isDateInToday(meetingDate(m.id))
        case .week: Calendar.current.isDate(meetingDate(m.id), equalTo: Date(), toGranularity: .weekOfYear)
        case .unfiled: m.tags.isEmpty
        case let .folder(f): isIn(m.tags, f)  // subfolders included
        }
    }
}

struct MeetingRow: Identifiable, Hashable { let id: String; var title: String?; var tags: [String]; var recordingFlag: Bool }

/// A report page: a saved report, or (id nil) the one being written for the folder, else its latest.
struct OpenReport: Hashable { let folder: String; var id: String? }

/// Where the window is; Back returns to the previous one.
struct Page: Equatable { var scope: Scope; var selected: String?; var report: OpenReport?; var settings: Bool }

struct QA: Identifiable, Hashable { let id = UUID(); var q: String; var a: String?; var failed = false }

let silenceEnd: TimeInterval = 180  // no speech for this long ends the meeting
let micReleaseEnd: TimeInterval = 10  // the call apps released the microphone this long ago
let resumeWithin: TimeInterval = 3600  // an interrupted meeting can be continued from the call prompt for this long

/// A warning alert with a destructive button and Cancel (Esc). True when the destructive button was clicked.
func confirm(_ title: String, _ text: String, _ button: String) -> Bool {
    let a = NSAlert()
    a.alertStyle = .warning
    a.messageText = title
    a.informativeText = text
    a.addButton(withTitle: button).hasDestructiveAction = true
    a.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
    return a.runModal() == .alertFirstButtonReturn
}

final class Model: ObservableObject {
    static let shared = Model()

    @Published var meetings: [MeetingRow] = []
    @Published var scope: Scope = .all { didSet { settingsOpen = false; openReport = nil; choosing = nil; pageChanged() } }
    @Published var selected: String? { didSet { if selected != nil { settingsOpen = false; openReport = nil }; pageChanged() } }
    /// A report is shown in place of the meeting or folder page.
    @Published var openReport: OpenReport? { didSet { pageChanged() } }
    /// The Settings page is open in place of the meeting, folder or home page.
    @Published var settingsOpen = false { didSet { pageChanged() } }

    // MARK: back

    var page: Page { Page(scope: scope, selected: selected, report: openReport, settings: settingsOpen) }
    @Published private(set) var history: [Page] = []
    private var shown: Page?, noting = false

    /// One history step per click, however many of the fields above it changed: noted on the next run loop turn.
    private func pageChanged() {
        guard !noting else { return }
        noting = true
        DispatchQueue.main.async { [self] in
            noting = false
            let p = page
            if let s = shown, s != p { history.append(s); if history.count > 100 { history.removeFirst() } }
            shown = p
        }
    }

    /// Change the page without a history step (a report that finished writing replaces its "writing" page).
    private func replacePage(_ change: () -> Void) { change(); shown = page }

    func back() {
        while let p = history.popLast() {
            if let id = p.selected, !meetings.contains(where: { $0.id == id }) { continue }  // deleted since
            if case let .folder(f) = p.scope, !folders.contains(where: { $0.name == f }) { continue }  // deleted or renamed since
            replacePage { scope = p.scope; selected = p.selected; openReport = p.report; settingsOpen = p.settings }
            return
        }
    }

    func showSettings() {
        settingsOpen = true
        openMain?()
        NSApp.activate(ignoringOtherApps: true)
    }
    /// The first-run setup (model download, permissions, AI) is shown over the main window.
    @Published var showSetup = !UserDefaults.standard.bool(forKey: "setupDone")
    @Published var revision = 0  // bumped when files changed on disk; open views reload
    @Published var toast: String?
    @Published var threads: [String: [QA]] = [:]  // chat per scope: "m:<id>", "f:<folder>", "all"
    @Published var pinned = UserDefaults.standard.bool(forKey: "miniPinned") { didSet { UserDefaults.standard.set(pinned, forKey: "miniPinned") } }

    // The active meeting
    @Published var activeId: String?
    @Published var status = Status.idle {
        // A GUI app in the background gets App Nap after ~a minute: audio, recognition and the transcript stall. Opt out while busy.
        didSet {
            if busy && activity == nil { activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Recording a meeting") }
            if !busy, let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
        }
    }
    private var activity: NSObjectProtocol?
    @Published var detail = ""
    @Published var lines: [Line] = []
    @Published var hearing: Set<String> = []  // voice heard, text not in yet: typing dots
    /// "Me" is not transcribed while this is on, for meetings where you mostly listen and talk to the room. Off again for each new recording.
    @Published var micMuted = false {
        didSet {
            recorder?.micOn = !micMuted
            if micMuted { hearing.remove("mic") }
        }
    }

    var busy: Bool { [.recording, .finalizing, .summarizing].contains(status) }
    var openMain: (() -> Void)?  // set by a SwiftUI view that has openWindow

    private var part = 0
    private var turns: [Turn] = []  // who spoke when in "Them", for this recording
    private var recorder: Recorder?
    private var lastSpeech: Date?, micSeen = false, micEmptySince: Date?
    private var toastTimer: Timer?

    init() {
        try? FileManager.default.createDirectory(at: meetingsDir, withIntermediateDirectories: true)
        Store.migrateLatestReports()
        reload()
        shown = page
    }

    @Published var folderEmoji: [String: String] = [:]
    @Published var library = TemplateLibrary()
    private var emptyFolders: Set<String> = []  // made with + or given a template, maybe with no meeting in them yet

    func reload() {
        meetings = Store.ids().map { MeetingRow(id: $0, title: Store.title($0), tags: Store.tags($0), recordingFlag: Store.recordingFlag($0)) }
        let meta = Store.folderMeta
        library = Store.library
        emptyFolders = Set(library.folders.keys).union(meta.keys)
        var emoji = meta.compactMapValues { $0["emoji"] }
        for f in Set(meetings.flatMap(\.tags)).union(emptyFolders).sorted() where emoji[f] == nil {  // folders from before emojis get one now
            emoji[f] = randomFolderEmoji(avoiding: emoji.values)
            Store.setFolderEmoji(f, emoji[f]!)
        }
        folderEmoji = emoji
        revision += 1
        // ponytail: reads every transcript on each reload; fine for hundreds of meetings, keep lengths in meta.json if it gets slow
        let ids = meetings.map(\.id)
        DispatchQueue.global().async {
            let l = Dictionary(uniqueKeysWithValues: ids.map { id in let lines = Store.lines(id); return (id, lines.count > 1 ? (lines.last!.t - lines.first!.t) / 60000 : 0) })
            DispatchQueue.main.async { self.lengths = l }
        }
    }

    /// Minutes each meeting lasted (first to last line), for the meeting list.
    @Published var lengths: [String: Int] = [:]

    /// Every folder as a tree (parents first; a subfolder is "Parent/Child") with how many meetings are in it and its subfolders.
    var folders: [(name: String, count: Int)] {
        folderTree(Set(meetings.flatMap(\.tags)).union(emptyFolders)).map { f in (f, meetings.filter { isIn($0.tags, f) }.count) }
    }

    /// This folder's settings sheet is open (the gear in the toolbar).
    @Published var folderSettings: String?
    /// A subfolder is being made inside this folder (right click, New Subfolder).
    @Published var newFolderParent: String?

    func folderExists(_ name: String) -> Bool { folders.contains { $0.name.lowercased() == name.trimmingCharacters(in: .whitespaces).lowercased() } }

    /// A new empty folder (inside `parent` when given), opened right away.
    func createFolder(_ name: String, emoji: String, parent: String? = nil) {
        let leaf = name.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-")
        let n = parent.map { "\($0)/\(leaf)" } ?? leaf
        guard !leaf.isEmpty, !folderExists(n) else { return }
        Store.setFolderEmoji(n, emoji)
        reload()
        scope = .folder(n); selected = nil
    }

    func setFolderEmoji(_ folder: String, _ emoji: String) {
        Store.setFolderEmoji(folder, emoji)
        reload()
    }

    /// Asks first, then takes the folder and its subfolders away. Their meetings stay: in their other folders, else in No Folder.
    /// The folders' reports go to the Trash.
    func deleteFolder(_ folder: String) {
        guard !writingUpdate.contains(where: { isIn([$0], folder) }) else { return fail("Not now: a report for this folder is being written") }
        let n = meetings.filter { isIn($0.tags, folder) }.count, subs = folders.filter { isIn([$0.name], folder) }.count - 1
        let what = (subs > 0 ? "Its \(subs) subfolder\(subs == 1 ? "" : "s") go\(subs == 1 ? "es" : "") too. " : "")
            + (n > 0 ? "The \(n) meeting\(n == 1 ? "" : "s") in it stay\(n == 1 ? "s" : ""), in No Folder or in their other folders. " : "")
            + "Its reports are moved to the Trash."
        guard confirm("Delete the folder \u{201C}\(folderPath(folder))\u{201D}?", what, "Delete Folder") else { return }
        for id in Store.ids() where isIn(Store.tags(id), folder) { Store.setTags(id, Store.tags(id).filter { !isIn([$0], folder) }) }
        Store.removeFolder(folder)
        var lib = Store.library
        lib.folders = lib.folders.filter { !isIn([$0.key], folder) }
        Store.saveLibrary(lib)
        threads = threads.filter { !($0.key.hasPrefix("f:") && isIn([String($0.key.dropFirst(2))], folder)) }
        if let f = folderSettings, isIn([f], folder) { folderSettings = nil }
        if let r = openReport, isIn([r.folder], folder) { openReport = nil }
        if case let .folder(f) = scope, isIn([f], folder) { scope = .all; selected = nil }
        reload()
    }

    /// The app quit or crashed while this meeting was recording, and it was not summarised since.
    func interrupted(_ id: String) -> Bool { id != activeId && (meetings.first { $0.id == id }?.recordingFlag ?? Store.recordingFlag(id)) }

    func title(_ id: String) -> String { meetings.first { $0.id == id }?.title ?? fallbackTitle(id) }

    func fail(_ message: String) {
        toast = message
        toastTimer?.invalidate()
        toastTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in self?.toast = nil }
    }

    /// Bring up the main window on a meeting (from the popup, the menu bar or an answer's link).
    func show(_ id: String?) {
        if let id { scope = .all; selected = id }
        openMain?()
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: recording

    func startNew() {
        guard !busy else { return fail("Another meeting is recording or being processed") }
        let id = Store.create()
        activeId = id; lines = []; part = 0
        pinned = false  // a pin is for one meeting: a new one opens its popup unpinned
        begin()
        selected = id
    }

    func resume(_ id: String) {
        guard activate(id) else { return fail("Not now: a meeting is recording or being processed") }
        begin()
    }

    /// Make a saved meeting the active one, to resume recording or redo its summary. Fails while another one is busy.
    private func activate(_ id: String) -> Bool {
        if id == activeId { return !busy }
        if busy { return false }
        lines = Store.lines(id)
        part = lines.map(\.part).max() ?? 0
        activeId = id; status = .done; detail = ""
        return true
    }

    private func begin() {
        guard let id = activeId else { return }
        part += 1
        lastSpeech = nil; micSeen = false; micEmptySince = nil
        Store.updateMeta(id, ["recording": true])  // stays set if the app dies mid-meeting, see interrupted()
        status = .recording; detail = ""; hearing = []; micMuted = false; turns = []
        let rec = Recorder()
        rec.onWindow = { [weak self] src, w, final, segs in self?.addWindow(id, src, w, final, segs) }
        rec.onHearing = { [weak self] src, on in
            guard let self, self.activeId == id else { return }
            if on && !(src == "mic" && self.micMuted) { self.hearing.insert(src) } else { self.hearing.remove(src) }
        }
        rec.onError = { [weak self] in self?.fail($0) }
        rec.onTurns = { [weak self] new in self?.addTurns(id, new) }
        recorder = rec
        reload()
        guard let model = Store.speechModel else { showSetup = true; return fail("The speech model is not downloaded yet: finish the setup first") }
        Task { await rec.start(model: model) }
    }

    private func addWindow(_ id: String, _ src: String, _ w: Int, _ final: Bool, _ segs: [Segment]) {
        guard activeId == id else { return }
        if !segs.isEmpty { lastSpeech = Date() }
        lines = labelSpeakers(replaceWindow(lines, src: src, w: w, part: part, final: final, segments: segs), turns)
        if final { Store.saveLines(id, lines) }
    }

    /// Voices numbered per recording part, so a resumed meeting's "Speaker 1" is not mixed up with the first part's.
    private func addTurns(_ id: String, _ new: [Turn]) {
        guard activeId == id else { return }
        turns += new.map { Turn(start: $0.start, end: $0.end, spk: "\(part)-\($0.spk)") }
        let before = lines
        lines = labelSpeakers(lines, turns)
        if lines != before { Store.saveLines(id, lines) }
    }

    /// Give a voice of "Them" a name, for this meeting's transcript, summaries and answers.
    func nameSpeaker(_ id: String, _ spk: String, _ name: String) {
        Store.nameSpeaker(id, spk, name)
        reload()
    }

    /// The End buttons: asks first, since a stopped recording can only be continued, not undone. The automatic stops do not ask.
    func endMeeting() {
        DispatchQueue.main.async { [self] in  // after the click's menu or popup has settled
            NSApp.activate(ignoringOtherApps: true)
            if confirm("End the meeting?", "Waffle stops recording and writes the notes. You can continue recording into this meeting later.", "End Meeting") { stop() }
        }
    }

    func stop(_ reason: String = "stopped") {
        guard status == .recording, let id = activeId, let rec = recorder else { return }
        status = .finalizing
        detail = "\(reason): finishing the last sentences"
        rec.stop { [self] in  // the recorder finalises its last windows first
            recorder = nil
            hearing = []
            lines = lines.map { var l = $0; l.final = true; return l }  // a window cut off by the stop is as final as it gets
            Store.saveLines(id, lines)
            Store.write(transcriptText(lines, names: Store.speakers(id)) + "\n", Store.dir(id).appendingPathComponent("transcript.md"))
            Store.updateMeta(id, ["recording": false])
            summarize()
        }
    }

    /// Redo the summary of any meeting, or make the first one for an interrupted meeting.
    /// Redo the summary (with another template, or the one it had), or make the first one for an interrupted meeting.
    func regenerate(_ id: String, template: String? = nil) {
        guard activate(id) else { return fail("Not now: a meeting is recording or being processed") }
        summarize(template: template)
    }

    /// The meeting's notes, with this template, else the one it had before, else the default.
    private func summarize(template: String? = nil) {
        guard let id = activeId else { return }
        status = .summarizing; detail = "writing the summary"
        reload()
        let input = "\(promptDateLine(id))\n\n\(Store.foldersText(id))\n\n\(Store.context(id, lines: lines))"
        let tpl = library.template(template ?? Store.meta(id)["template"] as? String ?? library.defaultId)
        let system = summarySystem(template: tpl)
        DispatchQueue.global().async {
            do {
                let (title, folders, speakers, notes) = parseSummary(try AI.ask(system: system, prompt: "Make the meeting notes.", context: input, cwd: Store.dir(id)))
                Store.addSummary(id, notes)
                let known = Store.allFolders()
                var meta: [String: Any] = ["recording": false, "template": tpl.id, "tags": Set(Store.tags(id) + (folders ?? []).filter(known.contains)).sorted { $0.lowercased() < $1.lowercased() }]  // only existing folders
                if let title, !title.isEmpty { meta["title"] = ["en": title] }
                Store.updateMeta(id, meta)
                // Names Claude could tell from the conversation, for voices the user has not named.
                let given = Store.speakers(id), shown = speakerNames(Store.lines(id), names: given)
                for (spk, label) in shown where given[spk] == nil { if let name = speakers[label] { Store.nameSpeaker(id, spk, name) } }
                DispatchQueue.main.async { self.status = .done; self.detail = ""; self.reload() }
            } catch {
                DispatchQueue.main.async {
                    self.fail("Summary: \(error.localizedDescription)")
                    self.status = .done; self.detail = "the summary failed, try again"; self.reload()
                }
            }
        }
    }

    /// Every 2 s: which call apps hold the microphone, and whether that ends the meeting.
    func watch() -> [String] {
        let apps = callApps()
        guard status == .recording else { return apps }
        if !apps.isEmpty { micSeen = true; micEmptySince = nil } else if micSeen && micEmptySince == nil { micEmptySince = Date() }
        if let t = micEmptySince, Date().timeIntervalSince(t) > micReleaseEnd { stop("the call ended") }
        else if let t = lastSpeech, Date().timeIntervalSince(t) > silenceEnd { stop("long silence") }
        return apps
    }

    /// An interrupted meeting touched within the last hour, offered by the call prompt.
    func resumable() -> (id: String, title: String)? {
        for m in meetings where interrupted(m.id) {
            let files = (try? FileManager.default.contentsOfDirectory(at: Store.dir(m.id), includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            let newest = files.compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }.max() ?? .distantPast
            if Date().timeIntervalSince(newest) < resumeWithin { return (m.id, m.title ?? fallbackTitle(m.id)) }
        }
        return nil
    }

    /// Quitting mid-meeting: keep what was heard. The meeting stays marked as recording, so it shows as interrupted next time.
    func quit() {
        guard let rec = recorder, let id = activeId else { return }
        rec.shutdown()
        Store.saveLines(id, lines.map { var l = $0; l.final = true; return l })
    }

    /// Meetings dropped on a folder in the sidebar (nil: No Folder) move there: out of the folder the list shows (and its subfolders), or,
    /// dragged from a Library list, out of every folder. Only real meeting ids count (anything else can be dragged in too).
    func moveToFolder(_ ids: [String], _ folder: String?) {
        let from: String? = if case let .folder(f) = scope { f } else { nil }
        for id in ids where meetings.contains(where: { $0.id == id }) {
            let kept = folder == nil ? [] : from.map { f in Store.tags(id).filter { !isIn([$0], f) } } ?? []
            Store.setTags(id, kept + (folder.map { [$0] } ?? []))
        }
        reload()
    }

    /// Put a meeting in a folder or take it out (the right-click menu; a meeting can be in several).
    func toggleFolder(_ id: String, _ folder: String) {
        let tags = Store.tags(id)
        Store.setTags(id, tags.contains(folder) ? tags.filter { $0 != folder } : tags + [folder])
        reload()
    }

    // MARK: summary templates

    /// Add or change one of the user's own templates, or keep the user's version of a built-in one.
    func saveTemplate(_ t: Template) {
        var lib = Store.library
        if lib.isBuiltin(t.id) { var e = t; e.about = lib.original(t.id)?.about; e.emoji = e.emoji ?? lib.original(t.id)?.emoji; lib.edited[t.id] = e }
        else if let i = lib.custom.firstIndex(where: { $0.id == t.id }) { lib.custom[i] = t } else { lib.custom.append(t) }
        Store.saveLibrary(lib); reload()
    }

    /// A built-in template back to how Waffle ships it.
    func resetTemplate(_ id: String) {
        var lib = Store.library
        lib.edited[id] = nil
        Store.saveLibrary(lib); reload()
    }

    func deleteTemplate(_ id: String) {
        var lib = Store.library
        lib.custom.removeAll { $0.id == id }
        lib.folders = lib.folders.filter { $0.value != id }
        if lib.defaultId == id { lib.defaultId = builtinTemplates[0].id }
        Store.saveLibrary(lib); reload()
    }

    func setDefaultTemplate(_ id: String) {
        var lib = Store.library
        lib.defaultId = id
        Store.saveLibrary(lib); reload()
    }

    /// nil: the folder's updates use the default template.
    func setFolderTemplate(_ folder: String, _ id: String?) {
        var lib = Store.library
        lib.folders[folder] = id
        Store.saveLibrary(lib); reload()
    }

    // MARK: updates for a period

    /// Today and This Week have reports too. Their reports and "writing" state use these keys in place of a folder name; they are never folders.
    static let scopeReports: [Scope: String] = [.today: "@today", .week: "@week"]

    /// "🌱 Standups" for a folder, "Today" or "This Week" for a Library list.
    func reportName(_ key: String) -> String {
        if let s = Model.scopeReports.first(where: { $0.value == key })?.key { return s.name }
        return "\(folderEmoji[key] ?? "📁") \(folderLeaf(key))"
    }

    /// The template of a folder's or Library list's reports; the default one until another is picked.
    func reportTemplate(_ key: String) -> Template {
        library.template(key.hasPrefix("@") ? UserDefaults.standard.string(forKey: "reportTemplate\(key)") : library.folders[key])
    }
    func setReportTemplate(_ key: String, _ id: String?) {
        if key.hasPrefix("@") { UserDefaults.standard.set(id, forKey: "reportTemplate\(key)"); objectWillChange.send() } else { setFolderTemplate(key, id) }
    }

    /// A report over every meeting of Today or This Week.
    func writeScopeReport(_ scope: Scope) {
        guard let key = Model.scopeReports[scope] else { return }
        let ids = meetings.filter(scope.contains).map(\.id)
        guard !ids.isEmpty else { return fail("No meetings for \(scope.name.lowercased())") }
        writeUpdate(key, ids, label: scope.name)
    }

    @Published var writingUpdate: Set<String> = []  // folders whose report Claude is writing

    /// Meetings being ticked for a report of this folder (the checkboxes in its meeting list).
    @Published var choosing: String? { didSet { chosen = [] } }
    @Published var chosen: Set<String> = []

    /// The folder's report period when none is picked (folder settings; This Week by default).
    func reportPeriod(_ folder: String) -> ReportPeriod { Store.folderMeta[folder]?["period"].flatMap(ReportPeriod.init) ?? .week }
    func setReportPeriod(_ folder: String, _ p: ReportPeriod) { Store.setFolderField(folder, "period", p.rawValue); reload() }

    /// A report over every meeting of the folder in the period (the folder's own period when none is given).
    func writeReport(_ folder: String, period: ReportPeriod? = nil) {
        let p = period ?? reportPeriod(folder)
        let ids = meetings.filter { isIn($0.tags, folder) && p.contains(meetingDate($0.id)) }.map(\.id)
        guard !ids.isEmpty else { return fail("No meetings in \(folder) for \(p.rawValue.lowercased())") }
        writeUpdate(folder, ids, label: p.rawValue)
    }

    /// One report over the picked meetings of a folder, shown right away (writing, then done); kept in the folder's report history.
    func writeUpdate(_ folder: String, _ ids: [String], label what: String = "Picked") {
        guard !ids.isEmpty, !writingUpdate.contains(folder) else { return }
        writingUpdate.insert(folder)
        choosing = nil
        selected = nil
        openReport = OpenReport(folder: folder)
        let dates = ids.map(meetingDate).sorted()
        let span = shortDay(dates.first!) == shortDay(dates.last!) ? shortDay(dates.first!) : "\(shortDay(dates.first!)) to \(shortDay(dates.last!))"
        let title = "\(what): \(ids.count) meeting\(ids.count == 1 ? "" : "s"), \(span)"
        let system = updatePrompt(template: reportTemplate(folder).text)
        DispatchQueue.global().async {
            do {
                let text = try AI.ask(system: system, prompt: "Write the update for these \(ids.count) meetings.", context: Store.meetingsContext(ids.sorted()), cwd: meetingsDir)
                let r = Report(id: idFormat.string(from: Date()), folder: folder, title: title, text: text)
                Store.addReport(r)
                DispatchQueue.main.async {
                    self.writingUpdate.remove(folder)
                    if self.openReport == OpenReport(folder: folder) { self.replacePage { self.openReport = OpenReport(folder: folder, id: r.id) } }
                    self.reload()
                }
            } catch {
                DispatchQueue.main.async { self.writingUpdate.remove(folder); self.fail("Report: \(error.localizedDescription)") }
            }
        }
    }

    // MARK: delete

    /// Asks twice, then moves the meeting's folder to the Trash (it can still be put back from Finder). Not while it records or is summarised.
    func delete(_ id: String) {
        guard !(id == activeId && busy) else { return fail("This meeting is still recording or being summarised") }
        let name = title(id)
        guard confirm("Delete \u{201C}\(name)\u{201D}?", "Its transcript, notes, summary and chat will be moved to the Trash.", "Delete"),
              confirm("Are you sure?", "\u{201C}\(name)\u{201D} disappears from Waffle. You can only get it back from the Trash in Finder.", "Delete Meeting")
        else { return }
        do {
            try FileManager.default.trashItem(at: Store.dir(id), resultingItemURL: nil)
        } catch {
            return fail("Could not delete: \(error.localizedDescription)")
        }
        if id == activeId { activeId = nil; lines = []; status = .idle; detail = "" }
        if selected == id { selected = nil }
        threads["m:\(id)"] = nil
        reload()
    }

    /// Asks first, then deletes the line.
    func confirmDeleteLine(_ id: String, _ line: Line) {
        if confirm("Delete this line?", "\u{201C}\(line.text)\u{201D}\n\nIt is removed from the transcript, so new summaries and answers will not use it.", "Delete") { deleteLine(id, line) }
    }

    /// Remove one line from a meeting's transcript, so later summaries and answers never see it. Only final lines: a grey one would come back
    /// with the next recognition pass.
    func deleteLine(_ id: String, _ line: Line) {
        guard line.final else { return }
        let rest = (id == activeId ? lines : Store.lines(id)).filter { $0 != line }
        if id == activeId { lines = rest }
        Store.saveLines(id, rest)
        let md = Store.dir(id).appendingPathComponent("transcript.md")
        if FileManager.default.fileExists(atPath: md.path) { Store.write(transcriptText(rest.filter(\.final), names: Store.speakers(id)) + "\n", md) }
        reload()
    }

    // MARK: chat

    func thread(_ key: String) -> [QA] {
        if let t = threads[key] { return t }
        guard key.hasPrefix("m:") else { return [] }
        return Store.chat(String(key.dropFirst(2))).map { QA(q: $0.q, a: $0.a) }
    }

    /// key "m:<id>" asks about one meeting (saved to its chat.jsonl), "f:<folder>" about a folder, "all" across all meetings.
    func ask(_ key: String, _ q: String) {
        var t = thread(key)
        let qa = QA(q: q, a: nil)
        t.append(qa)
        threads[key] = t
        let live = key.hasPrefix("m:") && String(key.dropFirst(2)) == activeId ? lines : nil
        DispatchQueue.global().async {
            var answer: String, failed = false
            do {
                if key.hasPrefix("m:") {
                    let id = String(key.dropFirst(2))
                    answer = try AI.ask(system: askPrompt, prompt: q, context: Store.context(id, lines: live ?? Store.lines(id)), cwd: Store.dir(id))
                    Store.appendChat(id, Chat(t: Int(Date().timeIntervalSince1970 * 1000), q: q, a: answer))
                } else {
                    let folder = key.hasPrefix("f:") ? String(key.dropFirst(2)) : nil
                    answer = try AI.ask(system: askAllPrompt, prompt: q, context: Store.askAllContext(folder: folder), cwd: meetingsDir)
                }
            } catch {
                answer = error.localizedDescription; failed = true
            }
            DispatchQueue.main.async {
                if let i = self.threads[key]?.firstIndex(where: { $0.id == qa.id }) { self.threads[key]![i].a = answer; self.threads[key]![i].failed = failed }
            }
        }
    }
}
