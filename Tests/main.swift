// Self-check for Sources/Logic.swift. Run: ./build.sh test
import Foundation

func line(_ t: Int, _ src: String, _ text: String) -> Line { Line(t: t, src: src, text: text, part: 1, final: true, w: t) }

// echo of the other side on the mic is dropped, my own words stay
let echo = [line(1000, "sys", "Any other questions? No? Great, let's wrap up."), line(1200, "mic", "Any other questions?"), line(9000, "mic", "Yes, I have a question about the release.")]
assert(dropEcho(echo).map(\.text) == [echo[0].text, echo[2].text])
assert(dropEcho([line(0, "sys", "The Port Amazo firewall upgrade is planned for October 7, from 7 to 9."), line(100, "mic", "The Port Amazo firewall upgrade is planned for October.")]).count == 1)

// one sentence per line, a sentence spread over segments is joined, timing follows the text position
let sent = splitSentences([(0.0, 4.0, " Hello there. How are"), (4.0, 6.0, " you today? Fine, Cry"), (6.0, 7.0, "ptic.")])
assert(sent.map(\.1) == ["Hello there.", "How are you today?", "Fine, Cryptic."], "\(sent)")
assert(sent[0].0 < 300 && 1000 < sent[1].0 && sent[1].0 < 4000 && sent[2].0 >= 4000, "\(sent)")
assert(splitSentences([(0, 2, " Thanks for watching!")]).isEmpty && splitSentences([]).isEmpty)
assert(splitSentences([(0, 2, " 🎵")]).isEmpty && splitSentences([(0, 2, " 🎵 Hello.")]).map(\.1) == ["🎵 Hello."])  // music marks alone are dropped

let s = parseSummary("TITLE: Redis Incident\nFOLDERS: Incidents, CAB\n# Redis\n- down")
assert(s.title == "Redis Incident" && s.folders == ["Incidents", "CAB"] && s.notes == "# Redis\n- down")
assert(parseSummary("TITLE: X\nFOLDERS:\n# A").folders == [] && parseSummary("# A\n- b").title == nil && parseSummary("# A\n- b").notes == "# A\n- b")
let named = parseSummary("TITLE: Sync\nFOLDERS:\nSPEAKERS: Speaker 1 = Oleg, Speaker 3 = Maryna Koval\n# A")
assert(named.speakers == ["Speaker 1": "Oleg", "Speaker 3": "Maryna Koval"] && named.notes == "# A" && parseSummary("TITLE: X\nSPEAKERS:\n# A").speakers.isEmpty)

// each pass over a window replaces that window's lines; other speakers' lines stay
var lines = [Line(t: 500, src: "mic", text: "Hi.", part: 1, final: true, w: 500)]
lines = replaceWindow(lines, src: "sys", w: 1000, part: 1, final: false, segments: [(0, 1, " Hello wor")])
lines = replaceWindow(lines, src: "sys", w: 1000, part: 1, final: false, segments: [(0, 2, " Hello world. Next one")])
assert(lines.map(\.text) == ["Hi.", "Hello world.", "Next one"], "\(lines)")

// passes over a long transcript only re-check the lines near the new ones, and end up the same as checking everything
var long: [Line] = [], full: [Line] = []
for k in 0..<120 {
    let w = k * 7000, src = k % 3 == 0 ? "mic" : "sys"
    let text = k % 9 == 0 ? "We ship the release on Monday at ten." : "Line number \(k) about topic \(k % 5)."
    long = replaceWindow(long, src: src, w: w, part: 1, final: true, segments: [(0, 2, text)])
    full = dropEcho((full + [Line(t: w, src: src, text: text, part: 1, final: true, w: w)]).sorted { $0.t < $1.t })
}
assert(long == full && long.count < 120, "\(long.count) \(full.count)")
assert(firstIndex(5) { $0 >= 3 } == 3 && firstIndex(5) { _ in false } == 5 && firstIndex(0) { _ in true } == 0)

// a summary prompt is the fixed rules, the template, then the fixed title / folders / speakers layout
let haiku = Template(id: "x", name: "Haiku", text: "Write haiku.")
assert(summarySystem(template: haiku).hasPrefix("You turn a meeting") && summarySystem(template: haiku).contains("Write haiku.") && summarySystem(template: haiku).hasSuffix("call people by those names."))
assert(builtinTemplates.count == 10 && Set(builtinTemplates.map(\.id)).count == 10 && builtinTemplates[0].id == TemplateLibrary().defaultId)
// old folder templates and old custom instructions become the user's own templates; a missing template falls back to the default
let lib = migrateTemplates(["CAB": "One heading per change."], customPrompt: " Write haiku. ")
assert(lib.defaultId == "my-instructions" && lib.custom.map(\.name) == ["My instructions", "CAB"] && lib.folders["CAB"] == "folder-CAB", "\(lib)")
assert(lib.template("gone").id == "my-instructions" && TemplateLibrary().template(nil).id == "waffle" && migrateTemplates([:], customPrompt: "") == TemplateLibrary())

// copy keeps real nesting and bold for Slack; headings become bold lines
assert(summaryHTML("# Topic\n- a **b**\n  - c\n- d") == "<p><b>Topic</b></p><ul><li>a <b>b</b><ul><li>c</li></ul></li><li>d</li></ul>", summaryHTML("# Topic\n- a **b**\n  - c\n- d"))

// 24-hour dates
assert(fallbackTitle("2026-09-29_15-29-24") == "Meeting 29 Sep, 15:29" && fullDate("2026-09-29_16-04-19") == "Tue, 29 September 2026 at 16:04")
assert(elapsed(754) == "12:34" && elapsed(3723) == "1:02:03")

// finished sentences are locked; the open last sentence and one ending near the audio edge stay open
let toks: [Segment] = [(0.1, 0.4, " Hello"), (0.4, 0.5, " there."), (1.0, 1.3, " How"), (1.3, 1.6, " are"), (1.6, 2.0, " you?"), (3.0, 3.2, " Fine")]
let ss = sentences(toks)
assert(ss.map(\.text) == ["Hello there.", "How are you?", "Fine"] && ss[0].tokenEnd == 2 && ss[0].end == 0.5 && ss[0].next == 1.0 && ss[2].next == nil, "\(ss)")
assert(sentences([(0, 1, " v1."), (1, 2, "2 is out.")]).count == 1)  // "v1.2" is not a sentence end
assert(lockableSentences(ss, audioEnd: 5) == 2)
assert(lockableSentences(ss, audioEnd: 2.5) == 1)  // the second ends too close to the edge
assert(lockableSentences(Array(ss.prefix(1)), audioEnd: 5) == 0)  // the only sentence may still grow

// each "Them" line gets the voice that overlaps it most; "Me" lines and uncovered lines are left alone
let talk = [Line(t: 0, src: "sys", text: "Hi.", part: 1, final: true, w: 0), Line(t: 2000, src: "mic", text: "Hello.", part: 1, final: true, w: 0),
            Line(t: 5000, src: "sys", text: "Status?", part: 1, final: true, w: 0), Line(t: 60000, src: "sys", text: "Later.", part: 1, final: true, w: 0)]
let turns = [Turn(start: 0, end: 4800, spk: "1-1"), Turn(start: 4800, end: 5200, spk: "1-1"), Turn(start: 5200, end: 9000, spk: "1-2")]
let labelled = labelSpeakers(talk, turns)
assert(labelled.map(\.spk) == ["1-1", nil, "1-2", nil], "\(labelled.map(\.spk))")
// the same with turns out of order, and with a long turn that started well before the line
assert(labelSpeakers(talk, turns.reversed()).map(\.spk) == labelled.map(\.spk))
assert(labelSpeakers(talk, [Turn(start: -50000, end: 1000, spk: "1-3"), Turn(start: 5500, end: 6000, spk: "1-1")]).map(\.spk) == ["1-3", nil, "1-1", nil])
let names = speakerNames(labelled, names: ["1-2": "Oleg"])
assert(names == ["1-1": "Speaker 1", "1-2": "Oleg"] && labelled.map { label($0, names) } == ["Speaker 1", "Me", "Oleg", "Them"])
assert(speakerNames(Array(labelled.prefix(2)), names: [:]) == ["1-1": "Them"])  // one voice only: plain "Them"
assert(transcriptText(Array(labelled.prefix(3)), names: ["1-2": "Oleg"]).hasSuffix("Oleg: Status?"))
// copy: "Who: what they said", a speaker's run of lines joined into one line
assert(transcriptCopy(labelled, names: ["1-2": "Oleg"]) == "Speaker 1: Hi.\nMe: Hello.\nOleg: Status?\nThem: Later.", transcriptCopy(labelled, names: ["1-2": "Oleg"]))
assert(transcriptCopy([line(0, "mic", "One."), line(1, "mic", "Two."), line(2, "sys", "Three.")]) == "Me: One. Two.\nThem: Three." && transcriptCopy([]) == "")
// names from the call window: who talks, who is there, which voice is whom
assert(personName("Oleg Petrenko (Host)") == "Oleg Petrenko" && personName("Олег Петренко, muted") == "Олег Петренко" && personName("Maryna O'Neil-Koval") == "Maryna O'Neil-Koval")
assert(personName("Share Screen") == nil && personName("Oleg") == nil && personName("Oleg", minWords: 1) == "Oleg" && personName("room 42 B") == nil && personName("Leave") == nil)
assert(speakingNames(["Talking: Oleg Petrenko", "Maryna Koval is speaking", "Ivan, speaking", "Anna Bell (speaking)", "Говорить: Олег", "Not speaking", "Mute"]) == ["Oleg Petrenko", "Maryna Koval", "Ivan", "Anna Bell", "Олег"], "\(speakingNames(["Talking: Oleg Petrenko", "Maryna Koval is speaking", "Ivan, speaking", "Anna Bell (speaking)", "Говорить: Олег", "Not speaking", "Mute"]))")
assert(speakingNames(["You are speaking", "Speaking", "Oleg Petrenko"]).isEmpty)
assert(rosterNames(["Weekly Sync | Microsoft Teams", "Sprint Planning", "Design Review", "Zoom Meeting - Oleg Petrenko"]).isEmpty)
assert(rosterNames(["Oleg Petrenko (Host)", "Start Video", "Participants (3)", "Maryna Koval", "Oleg Petrenko", "Raise Hand"]) == ["Oleg Petrenko", "Maryna Koval"])
let screenTurns = [Turn(start: 0, end: 10000, spk: "1-1"), Turn(start: 10000, end: 20000, spk: "1-2"), Turn(start: 20000, end: 30000, spk: "1-3")]
let shown: [(t: Int, name: String)] = [(1000, "Oleg"), (4000, "Oleg"), (7000, "Oleg"), (9000, "Maryna"), (12000, "Maryna"), (15000, "Maryna"), (18000, "Maryna"), (22000, "Ivan"), (25000, "Ivan")]
assert(screenSpeakers(screenTurns, shown) == ["1-1": "Oleg", "1-2": "Maryna"], "\(screenSpeakers(screenTurns, shown))")  // Ivan: only 2 looks
assert(screenSpeakers(screenTurns.reversed(), shown) == ["1-1": "Oleg", "1-2": "Maryna"] && screenSpeakers([], shown).isEmpty)
assert(screenSpeakers([Turn(start: 0, end: 9000, spk: "1-1"), Turn(start: 10000, end: 19000, spk: "1-2")], [(1000, "Oleg"), (2000, "Oleg"), (3000, "Oleg"), (11000, "Oleg"), (12000, "Oleg"), (13000, "Oleg")]).isEmpty)  // one name for two voices: neither
let bare = [line(1000, "sys", "Hi all."), line(6000, "sys", "Next."), line(20000, "sys", "Both?"), line(30000, "mic", "Me.")]
let fromScreen = labelFromScreen(bare, [(1500, "Oleg"), (7000, "Maryna"), (20500, "Oleg"), (21000, "Maryna"), (30500, "Ivan")])
assert(fromScreen.map(\.spk) == ["@Oleg", "@Maryna", nil, nil], "\(fromScreen.map(\.spk))")
assert(speakerNames(fromScreen, names: [:]) == ["@Oleg": "Oleg", "@Maryna": "Maryna"] && transcriptCopy(fromScreen).hasPrefix("Oleg: Hi all.\nMaryna: Next.\nThem: Both?"))
let mixed = labelFromScreen(labelled, [(60500, "Ivan")])
assert(speakerNames(mixed, names: [:]) == ["1-1": "Speaker 1", "1-2": "Speaker 2", "@Ivan": "Ivan"] && speakerNames([mixed[0], mixed[3]], names: [:]) == ["1-1": "Speaker 1", "@Ivan": "Ivan"])
// old transcripts without "spk" still load
assert(try! JSONDecoder().decode(Line.self, from: Data(#"{"t":1,"src":"sys","text":"x","part":1,"final":true}"#.utf8)).spk == nil)

// report periods
let noon = idFormat.date(from: "2026-09-30_12-00-00")!
assert(ReportPeriod.today.contains(meetingDate("2026-09-30_09-00-00"), now: noon) && !ReportPeriod.today.contains(meetingDate("2026-09-29_23-00-00"), now: noon))
assert(ReportPeriod.last7.contains(meetingDate("2026-09-24_13-00-00"), now: noon) && !ReportPeriod.last7.contains(meetingDate("2026-09-22_12-00-00"), now: noon))
assert(ReportPeriod.month.contains(meetingDate("2026-09-01_08-00-00"), now: noon) && !ReportPeriod.month.contains(meetingDate("2026-08-31_08-00-00"), now: noon))

// the library loads files written before "edited" existed, and edited built-ins replace the original in the list
let older = try! JSONDecoder().decode(TemplateLibrary.self, from: Data(#"{"custom":[],"defaultId":"brief","folders":{"CAB":"cab"}}"#.utf8))
assert(older.defaultId == "brief" && older.folders == ["CAB": "cab"] && older.edited.isEmpty)
var mine = TemplateLibrary(); mine.edited["brief"] = Template(id: "brief", name: "Brief", text: "Mine.")
assert(mine.all.count == 10 && mine.template("brief").text == "Mine." && mine.isEdited("brief") && mine.original("brief")!.text != "Mine.")

// subfolders are paths; a parent holds its subfolders' meetings; the tree lists parents first
assert(isIn(["Project/Standups"], "Project") && isIn(["Project"], "Project") && !isIn(["Projects"], "Project") && !isIn(["Project"], "Project/Standups"))
assert(folderTree(["Project/Standups", "Alpha", "project x"]) == ["Alpha", "Project", "Project/Standups", "project x"], "\(folderTree(["Project/Standups", "Alpha", "project x"]))")
assert(folderLeaf("Project/Standups") == "Standups" && folderDepth("Project/Standups") == 1 && folderPath("A/B") == "A \u{203A} B")

// renaming a folder takes its subfolders along and leaves look-alike names alone
assert(renamedFolder("Project", from: "Project", to: "Work") == "Work" && renamedFolder("Project/Standups", from: "Project", to: "Work") == "Work/Standups")
assert(renamedFolder("Projects", from: "Project", to: "Work") == "Projects" && renamedFolder("A/Project", from: "Project", to: "Work") == "A/Project")
assert(renamedFolder("A/B/C", from: "A/B", to: "A/X") == "A/X/C")

let tree = folderTree(["A/x", "A/y/1", "A/y/2", "B"])  // A ├x └y ├1 └2, B
assert(treeGuides("A", in: tree) == [] && treeGuides("A/x", in: tree) == [true] && treeGuides("A/y", in: tree) == [false])
assert(treeGuides("A/y/1", in: tree) == [false, true] && treeGuides("A/y/2", in: tree) == [false, false])

let wed = meetingDate("2026-09-30_12-00-00")
assert(dayHeading(meetingDate("2026-09-30_08-00-00"), now: wed) == "Today" && dayHeading(meetingDate("2026-09-29_23-59-00"), now: wed) == "Yesterday")
assert(dayHeading(meetingDate("2026-09-28_11-30-00"), now: wed) == "Monday, 28 Sep", dayHeading(meetingDate("2026-09-28_11-30-00"), now: wed))

print("ok")
