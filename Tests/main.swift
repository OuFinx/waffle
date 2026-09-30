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
let names = speakerNames(labelled, names: ["1-2": "Oleg"])
assert(names == ["1-1": "Speaker 1", "1-2": "Oleg"] && labelled.map { label($0, names) } == ["Speaker 1", "Me", "Oleg", "Them"])
assert(speakerNames(Array(labelled.prefix(2)), names: [:]) == ["1-1": "Them"])  // one voice only: plain "Them"
assert(transcriptText(Array(labelled.prefix(3)), names: ["1-2": "Oleg"]).hasSuffix("Oleg: Status?"))
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

let tree = folderTree(["A/x", "A/y/1", "A/y/2", "B"])  // A ├x └y ├1 └2, B
assert(treeGuides("A", in: tree) == [] && treeGuides("A/x", in: tree) == [true] && treeGuides("A/y", in: tree) == [false])
assert(treeGuides("A/y/1", in: tree) == [false, true] && treeGuides("A/y/2", in: tree) == [false, false])

let wed = meetingDate("2026-09-30_12-00-00")
assert(dayHeading(meetingDate("2026-09-30_08-00-00"), now: wed) == "Today" && dayHeading(meetingDate("2026-09-29_23-59-00"), now: wed) == "Yesterday")
assert(dayHeading(meetingDate("2026-09-28_11-30-00"), now: wed) == "Monday, 28 Sep", dayHeading(meetingDate("2026-09-28_11-30-00"), now: wed))

print("ok")
