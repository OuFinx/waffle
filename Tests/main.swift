// Self-check for Sources/Logic.swift. Run: ./build.sh test
import Foundation

func line(_ t: Int, _ src: String, _ text: String) -> Line { Line(t: t, src: src, text: text, part: 1, final: true, w: t) }

// echo of the other side on the mic is dropped, my own words stay
let echo = [line(1000, "sys", "Any other questions? No? Great, let's wrap up."), line(1200, "mic", "Any other questions?"), line(9000, "mic", "Yes, I have a question about the release.")]
assert(dropEcho(echo).map(\.text) == [echo[0].text, echo[2].text])
assert(dropEcho([line(0, "sys", "The Port Amazo firewall upgrade is planned for October 7, from 7 to 9."), line(100, "mic", "The Port Amazo firewall upgrade is planned for October.")]).count == 1)
// short answers are mine, not echoes, even when "Them" said the same word a moment before or after
for (them, me) in [("Yes, I can hear you.", "Can you hear me?"), ("Okay, so let's start with the release.", "Okay."), ("Is it done? Yes, I think so.", "Yes."),
                   ("No, we didn't ship it yet.", "No, no, no."), ("It makes sense to me.", "Makes sense."), ("Right, exactly what Oleg said.", "Right, exactly."),
                   ("Я згоден з Олегом.", "Я згоден."), ("Let's do Monday then.", "Let's do Monday.")] {
    assert(dropEcho([line(0, "sys", them), line(3000, "mic", me)]).count == 2, me)
}
// my words that they repeat later stay mine; a short echo right at their line's start goes
assert(dropEcho([line(0, "mic", "The code is four seven one nine."), line(9000, "sys", "The code is four seven one nine, got it.")]).count == 2)
assert(dropEcho([line(5000, "sys", "Great, thanks everyone."), line(5200, "mic", "Great.")]).count == 1)
assert(dropEcho([line(0, "sys", "Line number 4 about topic 4."), line(7000, "mic", "Line number 3 about topic 3.")]).count == 2)  // 7 s later: not an echo

// one sentence per line, a sentence spread over segments is joined, timing follows the text position
let sent = splitSentences([(0.0, 4.0, " Hello there. How are"), (4.0, 6.0, " you today? Fine, Cry"), (6.0, 7.0, "ptic.")])
assert(sent.map(\.1) == ["Hello there.", "How are you today?", "Fine, Cryptic."], "\(sent)")
assert(sent[0].0 < 300 && 1000 < sent[1].0 && sent[1].0 < 4000 && sent[2].0 >= 4000, "\(sent)")
assert(splitSentences([(0, 2, " Thank you.")]).map(\.1) == ["Thank you."] && splitSentences([(0, 2, " [music]")]).isEmpty && splitSentences([]).isEmpty)  // real speech stays
assert(splitSentences([(0, 2, " Включи субтитры, пожалуйста. (Laughs) okay, fine (really).")]).map(\.1) == ["Включи субтитры, пожалуйста.", "(Laughs) okay, fine (really)."])
assert(splitSentences([(0, 4, " Mr. Smith joins at 3 p.m. tomorrow. J. R. Smith too. Done!")]).map(\.1) == ["Mr. Smith joins at 3 p.m. tomorrow.", "J. R. Smith too.", "Done!"])
assert(splitSentences([(0, 2, " Τι ώρα είναι; Είναι τρεις.")]).map(\.1) == ["Τι ώρα είναι;", "Είναι τρεις."] && splitSentences([(0, 2, " Wait; what.")]).count == 1)
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
    let w = k * 7000 + (k % 4 == 1 ? -6800 : 0), src = k % 4 == 1 ? "mic" : "sys"  // every 4th line, the mic echoes the line before
    let text = k % 4 == 1 ? "Line number \(k - 1) about topic \((k - 1) % 5)." : "Line number \(k) about topic \(k % 5)."
    long = replaceWindow(long, src: src, w: w, part: 1, final: true, segments: [(0, 2, text)])
    full = dropEcho((full + [Line(t: w, src: src, text: text, part: 1, final: true, w: w)]).sorted { $0.t < $1.t })
}
assert(long == full && long.count == 90, "\(long.count) \(full.count)")
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
assert(lockableSentences(ss, previous: ["Hello there.", "How are you?"], audioEnd: 5) == 2 && lockableSentences(ss, previous: ["Hello there.", "How old are you?"], audioEnd: 5) == 1)
assert(lockableSentences(ss, previous: [], audioEnd: 5) == 0)  // the first pass of a window locks nothing
assert(sentences([(0, 1, " Mr."), (1, 2, " Smith"), (2, 3, " left.")]).map(\.text) == ["Mr. Smith left."] && ss[1].start == 1.0)
assert(forcedCut([(0, 1, " a"), (1.1, 2, " b"), (3, 4, " c"), (4.1, 5, "d")], from: 0.5, to: 4.5) == 2)  // the widest pause, before a word

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
assert(personName("Petrenko, Oleg") == "Oleg Petrenko" && personName("Petrenko, Oleg (Guest)") == "Oleg Petrenko" && personName("Oleg Petrenko, Maryna Koval") == "Oleg Petrenko")
assert(selfName(["Maryna Koval", "Oleg Petrenko (Host, me)"]) == "Oleg Petrenko" && selfName(["Oleg Petrenko (You)"]) == "Oleg Petrenko" && selfName(["Олег (Я)"]) == "Олег" && selfName(["Maryna (Host)"]) == nil)
assert(speakingNames(["Олег не говорить", "Oleg is not talking"]).isEmpty)
assert(personName("Share Screen") == nil && personName("Oleg") == nil && personName("Oleg", minWords: 1) == "Oleg" && personName("room 42 B") == nil && personName("Leave") == nil)
assert(speakingNames(["Talking: Oleg Petrenko", "Maryna Koval is speaking", "Ivan, speaking", "Anna Bell (speaking)", "Говорить: Олег", "Not speaking", "Mute"]) == ["Oleg Petrenko", "Maryna Koval", "Ivan", "Anna Bell", "Олег"], "\(speakingNames(["Talking: Oleg Petrenko", "Maryna Koval is speaking", "Ivan, speaking", "Anna Bell (speaking)", "Говорить: Олег", "Not speaking", "Mute"]))")
assert(speakingNames(["You are speaking", "Speaking", "Oleg Petrenko"]).isEmpty)
assert(rosterNames(["Weekly Sync | Microsoft Teams", "Sprint Planning", "Design Review", "Zoom Meeting - Oleg Petrenko"]).isEmpty)
assert(rosterNames(["Oleg Petrenko (Host)", "Start Video", "Participants (3)", "Maryna Koval", "Oleg Petrenko", "Raise Hand"]) == ["Oleg Petrenko", "Maryna Koval"])
let screenTurns = [Turn(start: 0, end: 10000, spk: "1-1"), Turn(start: 10000, end: 20000, spk: "1-2"), Turn(start: 20000, end: 30000, spk: "1-3")]
let shown: [(t: Int, name: String)] = [(1000, "Oleg"), (4000, "Oleg"), (7000, "Oleg"), (9000, "Maryna"), (12000, "Maryna"), (15000, "Maryna"), (18000, "Maryna"), (22000, "Ivan"), (25000, "Ivan")]
assert(screenSpeakers(screenTurns, shown) == ["1-1": "Oleg", "1-2": "Maryna"], "\(screenSpeakers(screenTurns, shown))")  // Ivan: only 2 looks
assert(screenSpeakers(screenTurns.reversed(), shown) == ["1-1": "Oleg", "1-2": "Maryna"] && screenSpeakers([], shown).isEmpty)
let oleg3: [(t: Int, name: String)] = [(1000, "Oleg"), (2000, "Oleg"), (3000, "Oleg"), (11000, "Oleg"), (12000, "Oleg"), (13000, "Oleg")]
assert(screenSpeakers([Turn(start: 0, end: 9000, spk: "1-1"), Turn(start: 10000, end: 19000, spk: "1-2")], oleg3) == ["1-1": "Oleg", "1-2": "Oleg"])  // one person, two voices
assert(screenSpeakers([Turn(start: 0, end: 9000, spk: "1-1"), Turn(start: 10000, end: 19000, spk: "1-2"), Turn(start: 500, end: 3500, spk: "1-2")], oleg3).isEmpty)  // they talk at once: neither
assert(settleNames([:], ["1-1": "Oleg", "1-2": "Oleg"]) == ["1-1": "Oleg", "1-2": "Oleg"])
let bare = [line(1000, "sys", "Hi all."), line(6000, "sys", "Next."), line(20000, "sys", "Both?"), line(30000, "mic", "Me.")]
let fromScreen = labelFromScreen(bare, [(1500, "Oleg"), (7000, "Maryna"), (20500, "Oleg"), (21000, "Maryna"), (30500, "Ivan")])
assert(fromScreen.map(\.spk) == ["@Oleg", "@Maryna", nil, nil], "\(fromScreen.map(\.spk))")
assert(speakerNames(fromScreen, names: [:]) == ["@Oleg": "Oleg", "@Maryna": "Maryna"] && transcriptCopy(fromScreen).hasPrefix("Oleg: Hi all.\nMaryna: Next.\nThem: Both?"))

// names stay once given: a voice keeps its name, a line keeps the person it showed
assert(settleNames(["1-1": "Oleg"], ["1-1": "Maryna", "1-2": "Oleg", "1-3": "Ivan"]) == ["1-1": "Oleg", "1-3": "Ivan"])
assert(settleNames(["1-1": "Oleg"], [:]) == ["1-1": "Oleg"])  // the votes moved away: the name stays
func said(_ t: Int, _ spk: String?) -> Line { var l = line(t, "sys", "Hi."); l.spk = spk; return l }
let kept = keepNamed([said(0, "1-1"), said(5000, "@Maryna"), said(9000, nil), said(12000, "@Ivan")], [said(0, "1-2"), said(5000, "1-3"), said(9000, "1-2"), said(12000, "@Olena")], ["1-1": "Oleg"])
assert(kept.lines.map(\.spk) == ["1-1", "1-3", "1-2", "@Ivan"], "\(kept.lines.map(\.spk))")  // Oleg stays; Maryna's voice learns her name; Them may get a voice; Ivan stays
assert(kept.names == ["1-1": "Oleg", "1-3": "Maryna"], "\(kept.names)")
assert(keepNamed([said(0, "@Oleg")], [said(0, "1-2")], ["1-1": "Oleg"]).lines.map(\.spk) == ["@Oleg"])  // the name is another voice's: the line keeps it
assert(keepNamed([said(0, "1-1")], [said(0, "1-2")], ["1-1": "Oleg", "1-2": "Oleg"]).lines.map(\.spk) == ["1-2"])  // same name shown either way

assert(renamePeople(["Kabak Shamnmss", "Oleg Petrenko", "Babak Shammas"], ["Kabak Shamnmss": "Babak Shammas"]) == ["Babak Shammas", "Oleg Petrenko"])

// the call app's frame around who talks: tiles with a name in the corner or in the middle, an avatar ring, not buttons or other colours
func canvas(_ draw: (inout Pixels) -> Void) -> Pixels {
    var p = Pixels(w: 600, h: 400, rgba: [UInt8](repeating: 40, count: 600 * 400 * 4))
    draw(&p)
    return p
}
func paint(_ p: inout Pixels, _ x: Int, _ y: Int, _ c: (UInt8, UInt8, UInt8)) {
    guard x >= 0, y >= 0, x < p.w, y < p.h else { return }
    let i = (y * p.w + x) * 4; p.rgba[i] = c.0; p.rgba[i + 1] = c.1; p.rgba[i + 2] = c.2
}
func frame(_ p: inout Pixels, _ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ c: (UInt8, UInt8, UInt8)) {
    for t in 0..<3 {
        for x in x0...x1 { paint(&p, x, y0 + t, c); paint(&p, x, y1 - t, c) }
        for y in y0...y1 { paint(&p, x0 + t, y, c); paint(&p, x1 - t, y, c) }
    }
}
let zoomGreen: (UInt8, UInt8, UInt8) = (60, 200, 90), teamsViolet: (UInt8, UInt8, UInt8) = (127, 133, 245)
let corner = (name: "Oleg Petrenko", x: 60, y: 180, w: 90, h: 12), middle = (name: "Maryna", x: 380, y: 120, w: 60, h: 14)
assert(framedNames(canvas { frame(&$0, 50, 50, 260, 200, zoomGreen) }, [corner, middle]) == ["Oleg Petrenko"])
assert(framedNames(canvas { frame(&$0, 320, 40, 540, 220, teamsViolet) }, [corner, middle]) == ["Maryna"])  // camera off: name in the middle
assert(framedNames(canvas { frame(&$0, 50, 50, 260, 200, (220, 40, 40)) }, [corner]).isEmpty)  // a red annotation box
assert(framedNames(canvas { frame(&$0, 50, 50, 260, 200, (240, 180, 30)) }, [corner]).isEmpty)  // amber: a raised hand
assert(framedNames(canvas { frame(&$0, 55, 172, 160, 198, zoomGreen) }, [corner]).isEmpty)  // tight around the text: a selected button
assert(framedNames(canvas { p in frame(&p, 50, 50, 260, 200, zoomGreen); for y in 180..<192 { for x in 60..<150 { paint(&p, x, y, zoomGreen) } } }, [corner]).isEmpty)  // a green button
let ring = canvas { p in
    for a in 0..<720 { for r in 58...61 { let t = Double(a) * .pi / 360; paint(&p, 300 + Int(Double(r) * cos(t)), 150 + Int(Double(r) * sin(t)), teamsViolet) } }
}
assert(framedNames(ring, [(name: "Lynne Robbins", x: 262, y: 222, w: 76, h: 12)]) == ["Lynne Robbins"])
assert(framedNames(ring, [(name: "Lynne Robbins", x: 250, y: 222, w: 76, h: 12)]) == ["Lynne Robbins"])  // the name off centre: "Lynne Robbins (External)"
let disc = canvas { p in for y in 90...210 { for x in 240...360 where (x - 300) * (x - 300) + (y - 150) * (y - 150) <= 3600 { paint(&p, x, y, teamsViolet) } } }
assert(framedNames(disc, [(name: "Lynne Robbins", x: 262, y: 222, w: 76, h: 12)]).isEmpty)  // an avatar of initials on a coloured disc
let three = [(name: "Anna", x: 30, y: 100, w: 40, h: 12), (name: "Ivan", x: 230, y: 100, w: 40, h: 12), (name: "Olena", x: 430, y: 100, w: 40, h: 12)]
let tiles = canvas { p in for i in 0..<3 { frame(&p, 20 + i * 200, 10, 180 + i * 200, 125, teamsViolet) } }
assert(framedNames(tiles, Array(three.prefix(2))) == ["Anna", "Ivan"] && framedNames(tiles, three).isEmpty)  // two talk over each other; three: the theme
assert(framedNames(Pixels(w: 0, h: 0, rgba: []), [corner]).isEmpty)
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

// the live windows: a made-up recognizer that knows when each word was said; whatever the window boundaries, every word ends up final
// once, in order, sentences get locked while the speaker keeps talking, and no pass is longer than the model takes
func speech(_ sentences: [String], from: Double, word: Double = 0.3, gap: Double = 0.05, pause: Double = 0.4) -> [(start: Int, end: Int, text: String)] {
    var t = from, out: [(start: Int, end: Int, text: String)] = []
    for s in sentences {
        for w in s.split(separator: " ") { out.append((Int(t * 16000), Int((t + word) * 16000), " " + w)); t += word + gap }
        t += pause
    }
    return out
}
let runOn = (0..<70).map { "w\($0)" }.joined(separator: " ")  // 24 s without a sentence end
let script = speech(["Good morning everyone.", "Let us start with the release.", "It is blocked on the database.", "Oleg will rotate the credentials."], from: 1)
    + speech(["Next topic is hiring.", "We have two candidates."], from: 15) + speech([runOn + "."], from: 22)
func recognize(_ p: Pass) -> [Segment] {
    let from = p.start - p.ctx, to = from + p.audio.count
    return script.filter { $0.start >= from && $0.end <= to }.map { (Double($0.start - from) / 16000, Double($0.end - from) / 16000, $0.text) }
}
for delayed in [false, true] {
    let win = Windower()
    var shown: [Int: (final: Bool, text: String)] = [:], finals = 0, longest = 0, waiting: [Pass] = []
    func take(_ e: [Emit]) {
        for x in e {
            if shown[x.start]?.final == true { assert(!x.final || x.segments.isEmpty, "a final window came back"); continue }
            shown[x.start] = (x.final, x.segments.map(\.text).joined())
            if x.final { finals += 1 }
        }
    }
    func run(_ ps: [Pass]) { for p in ps { longest = max(longest, p.audio.count); take(win.done(p, recognize(p))) } }
    let total = 16000 * 50
    for c in stride(from: 0, to: total, by: 4096) {
        let talking = script.contains { $0.start < c + 4096 && $0.end > c }
        let ps = win.push([Float](repeating: talking ? 0.1 : 0, count: 4096), speech: talking)
        if delayed { run(waiting); waiting = ps } else { run(ps) }
    }
    run(waiting); run(win.flush())
    let text = shown.sorted { $0.key < $1.key }.map(\.value.text).joined()
    assert(text == script.map(\.text).joined(), "delayed \(delayed): \(text)")
    assert(shown.values.allSatisfy(\.final) && finals >= 5 && longest <= 240_000, "\(finals) \(longest)")
}

// the same with random speech: sentence lengths, pauses, missing sentence ends and late answers from the recognizer
var rng: UInt64 = 42
func rand(_ n: Int) -> Int { rng = rng &* 6364136223846793005 &+ 1442695040888963407; return Int((rng >> 33) % UInt64(n)) }
for round in 0..<40 {
    var said: [(start: Int, end: Int, text: String)] = [], t = 0.5 + Double(rand(20)) / 10
    for k in 0..<(3 + rand(10)) {
        let n = 1 + rand(round % 3 == 0 ? 60 : 14)
        let words = (0..<n).map { "r\(round)s\(k)w\($0)" }.joined(separator: " ") + (rand(4) == 0 ? "" : ".")
        let part = speech([words], from: t, word: 0.15 + Double(rand(30)) / 100, gap: Double(rand(25)) / 100, pause: 0)
        said += part
        t = Double(part.last!.end) / 16000 + [0.1, 0.3, 0.5, 0.9, 1.5, 3.0][rand(6)]
    }
    let win = Windower()
    var shown: [Int: (final: Bool, text: String)] = [:], waiting: [[Pass]] = []
    func take(_ e: [Emit]) {
        for x in e where shown[x.start]?.final != true { shown[x.start] = (x.final, x.segments.map(\.text).joined()) }
    }
    // Like Parakeet: words in pieces ("▁w" "ord"), punctuation its own token, and times that move by up to 80 ms from pass to pass.
    func hear(_ p: Pass) -> [Segment] {
        let from = p.start - p.ctx, to = from + p.audio.count
        assert(p.audio.count <= 240_000)
        var out: [Segment] = []
        for w in said where w.start >= from && w.end <= to {
            let a = Double(w.start - from) / 16000, b = Double(w.end - from) / 16000, j = Double(rand(17) - 8) / 100
            var text = String(w.text.dropFirst()), punct = ""
            if text.hasSuffix(".") { text.removeLast(); punct = "." }
            let half = text.index(text.startIndex, offsetBy: text.count / 2)
            let mid = (a + b) / 2
            out.append((a + j, mid + j, " " + text[..<half]))
            out.append((mid + j, b + j, String(text[half...])))
            if !punct.isEmpty { out.append((b + j, b + j, punct)) }
        }
        return out
    }
    let delay = rand(3)
    // now and then the recognizer gives up on a pass that is not final (Parakeet does): nothing, or the first two words
    func flaky(_ p: Pass) -> [Segment] {
        let all = hear(p)
        guard !p.final, rand(7) == 0 else { return all }
        return rand(2) == 0 ? [] : Array(all.prefix(4))
    }
    for c in stride(from: 0, to: Int((t + 3) * 16000), by: 4096) {
        let talking = said.contains { $0.start < c + 4096 && $0.end > c }
        // the window may end at any moment (the stream stopped, the mic was muted, the Mac slept), even inside a word
        if rand(12) == 0 { waiting.append(win.flush()) }
        waiting.append(win.push([Float](repeating: 0, count: 4096), speech: talking))
        while waiting.count > delay { for p in waiting.removeFirst() { take(win.done(p, flaky(p))) } }
    }
    for ps in waiting + [win.flush()] { for p in ps { take(win.done(p, flaky(p))) } }
    let text = shown.sorted { $0.key < $1.key }.map(\.value.text).joined()
    assert(text == said.map(\.text).joined(), "round \(round): \(text)\nwanted \(said.map(\.text).joined())")
}
assert(Windower().push([Float](repeating: 0, count: 4096 * 100), speech: false).isEmpty)

// a pass that comes back with too few words for its speech, with context, is tried without it
let tw = Windower()
var tp: [Pass] = []
for c in 0..<40 { let ps = tw.push([Float](repeating: 0, count: 4096), speech: c >= 12); tp += ps; for p in ps { _ = tw.done(p, nil) } }  // speech after 3 s of quiet: context
let lastPass = tp.last!
let ctxSeconds = Double(lastPass.ctx) / 16000
let speechWords: [Segment] = (0..<20).map { k -> Segment in
    let a = Double(k) * 0.3 + ctxSeconds
    return (a, a + 0.25, " w\(k)")
}
assert(lastPass.ctx > 0 && lastPass.voiced > 16000 * 3, "\(lastPass.ctx) \(lastPass.voiced)")
assert(tw.thin(lastPass, Array(speechWords.prefix(2))) && !tw.thin(lastPass, speechWords) && lastPass.bare.ctx == 0 && lastPass.bare.audio.count == lastPass.audio.count - lastPass.ctx)
let bareWords: [Segment] = speechWords.map { ($0.start - ctxSeconds, $0.end - ctxSeconds, $0.text) }
assert(tw.words(lastPass.bare, bareWords) == 20)
tw.forgetContext(lastPass)
var after: [Pass] = []
for _ in 0..<12 { let ps = tw.push([Float](repeating: 0, count: 4096), speech: true); after += ps; for p in ps { _ = tw.done(p, nil) } }
assert(!after.isEmpty && after.allSatisfy { $0.ctx == 0 })  // the window goes on without the context

// wall time from the audio's own clock: a gap is a jump, a little jitter is not
var clock = ClockMap()
clock.mark(sample: 0, ms: 1000)
assert(!clock.mark(sample: 16000, ms: 2100) && clock.ms(16000) == 2000 && clock.mark(sample: 32000, ms: 5000) && clock.ms(32000 + 8000) == 5500 && clock.ms(8000) == 1500)

assert(clock.sample(5500) == 40000 && clock.sample(1500) == 8000)
var back = ClockMap(); back.mark(sample: 0, ms: 0); back.mark(sample: 16000, ms: 500); back.mark(sample: 8000, ms: 9000)
assert(back.anchors.map(\.sample) == [0, 8000] && back.ms(16000) == 9500)  // anchors stay in sample order
// the tape keeps speech with a little around it, timed on the wall clock across the quiet it leaves out
var tapeRec = Tape()
for k in 0..<20 { tapeRec.add([Float](repeating: k < 3 || (k > 8 && k < 11) ? 0.5 : 0, count: 4096), ms: Double(k) * 256, speech: k < 3 || (k > 8 && k < 11)) }
assert(tapeRec.pcm.count == 4096 * (3 + 4 + 2 + 2 + 4) && tapeRec.clock.ms(4096 * 7) == 7 * 256 && tapeRec.clock.ms(4096 * 9) == 9 * 256, "\(tapeRec.pcm.count) \(tapeRec.clock.anchors)")
var small = Tape(); small.cap = 5000
small.add([Float](repeating: 0.1, count: 4096), ms: 0, speech: true); small.add([Float](repeating: 0.1, count: 4096), ms: 256, speech: true)
assert(small.pcm.count == 4096 && small.full)

// the mic hearing the speakers is echo; the user's own voice over it is not
var seed: UInt64 = 7
func noise(_ n: Int) -> [Float] { (0..<n).map { _ in seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Float(Int64(bitPattern: seed >> 11) % 2000) / 10000 - 0.1 } }
let ref = noise(4096 + 4800), voice = noise(4096)
assert(echoLike(Array(ref[(4800 - 3200)..<(4800 - 3200 + 4096)]).map { $0 * 0.4 }, ref, maxLag: 4800))  // their sound, 200 ms later, quieter
assert(!echoLike(voice, ref, maxLag: 4800) && !echoLike([Float](repeating: 0, count: 4096), ref, maxLag: 4800))
assert(echoLike(Array(ref[(4800 - 960)..<(4800 - 960 + 4096)]).map { $0 * 0.02 }, ref.map { $0 * 0.1 }, maxLag: 4800))  // faint echo of quiet sound
assert(!echoLike(voice.map { $0 * 0.5 }, ref.map { $0 * 0.01 }, maxLag: 4800))  // the user loud over faint system audio

// quiet audio is brought up for the recognizer, loud audio down, without clipping; a quiet person after a loud one is brought up too,
// and the quiet between words stays quiet
func tone(_ n: Int, _ a: Float) -> [Float] { (0..<n).map { Float(sin(Double($0) / 10)) * a } }
func peakOf(_ x: ArraySlice<Float>) -> Float { x.map(abs).max()! }
let soft = tone(8000, 0.003) + [Float](repeating: 0, count: 8000) + tone(8000, 0.003)  // speech with a pause
let up = leveled(soft), down = leveled(soft.map { $0 * 300 })
assert(abs(peakOf(up[2000..<6000]) - 0.09) < 0.005 && peakOf(down[...]) <= 0.99, "\(peakOf(up[2000..<6000]))")
assert(leveled([Float](repeating: 0, count: 2000)) == [Float](repeating: 0, count: 2000))
let pair = leveled(tone(32000, 0.05) + tone(32000, 0.0008))
assert(peakOf(pair[44000..<60000]) > 0.02, "\(peakOf(pair[44000..<60000]))")  // the quiet one brought up 30 times, not left 50 times quieter
let gaps = leveled(tone(16000, 0.03) + (0..<32000).map { _ in Float.random(in: -0.003...0.003) } + tone(16000, 0.03))
assert(peakOf(gaps[24000..<40000]) < 0.05, "\(peakOf(gaps[24000..<40000]))")  // the noise between stays under a quarter of speech

// which app holds the microphone
assert(callAppName(bundle: "com.google.Chrome.helper", path: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper", name: "Google Chrome Helper") == "Google Chrome")
assert(callAppName(bundle: "com.apple.avconferenced", path: "/usr/libexec/avconferenced", name: nil) == "FaceTime" && callAppName(bundle: "com.apple.WebKit.GPU", path: "", name: nil) == "Safari")
assert(callAppName(bundle: "com.apple.corespeechd", path: "", name: nil) == nil && callAppName(bundle: "com.superduper.superwhisper", path: "/Applications/superwhisper.app/Contents/MacOS/superwhisper", name: "superwhisper") == nil)
assert(callAppName(bundle: "us.zoom.xos", path: "/Applications/zoom.us.app/Contents/MacOS/zoom.us", name: "zoom.us") == "zoom.us")

// after the call: the voices told apart again carry the live voices' names
func spoke(_ t: Int, _ spk: String) -> Line { var l = line(t, "sys", "Something said here."); l.spk = spk; return l }
let liveVoices = [spoke(1000, "2-1"), spoke(3000, "2-1"), spoke(5000, "@Oleg"), spoke(21000, "2-2"), spoke(23000, "2-2"), spoke(40000, "2-3")]
assert(carryVoices(live: liveVoices, turns: [Turn(start: 0, end: 10000, spk: "a"), Turn(start: 20000, end: 30000, spk: "b"), Turn(start: 39000, end: 41000, spk: "c")]) == ["a": "2-1", "b": "2-2"])
assert(oneOnOne(invited: ["Oleg Petrenko"], voices: ["2-1"]) == ["2-1": "Oleg Petrenko"] && oneOnOne(invited: ["A", "B"], voices: ["2-1"]).isEmpty)

print("ok")
