// The main window: sidebar (search, Library, Folders) | meeting list | meeting, folder or home page, with the chat pill at the bottom.
import Charts
import SwiftUI

let meColor = Color(light: .init(red: 0.14, green: 0.54, blue: 0.24, alpha: 1), dark: .init(red: 0.19, green: 0.82, blue: 0.35, alpha: 1))
let themColor = Color(light: .init(red: 0.04, green: 0.43, blue: 0.85, alpha: 1), dark: .init(red: 0.39, green: 0.67, blue: 1, alpha: 1))
/// The reading surface. Light: a neutral light grey (#F5F5F7, Apple's own page grey) instead of pure white, which glares on bright
/// screens, and not warm, which read as yellowish; white stays for the small things on top (cards, fields). Dark: the usual text background.
let paper = Color(light: .init(srgbRed: 0.961, green: 0.961, blue: 0.969, alpha: 1), dark: .textBackgroundColor)

extension Color {
    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }
}

func inline(_ s: String) -> AttributedString {
    (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
}

struct MainView: View {
    @EnvironmentObject var model: Model
    @Environment(\.openWindow) var openWindow
    @AppStorage("sidebar") var sidebarOpen = true
    @State var visibility = NavigationSplitViewVisibility.all
    @State var query = ""
    @State var hits: [SearchHit]?

    var body: some View {
        Group {
            if model.settingsOpen {
                // Settings takes the place of the list and the meeting: two columns while it is open.
                NavigationSplitView(columnVisibility: $visibility) {
                    Sidebar(searching: false)
                        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
                } detail: {
                    SettingsView()
                        .background(paper)
                        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                        .toolbar {
                            if #available(macOS 26.0, *) {
                                ToolbarItem(placement: .automatic) { BackButton() }.sharedBackgroundVisibility(.hidden)
                                ToolbarSpacer(.flexible)
                            } else {
                                ToolbarItem(placement: .navigation) { BackButton() }
                            }
                        }
                }
            } else {
                NavigationSplitView(columnVisibility: $visibility) {
                    Sidebar(searching: hits != nil)
                        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
                } content: {
                    MeetingList(hits: hits, query: query)
                        .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 420)
                } detail: {
                    Detail()
                }
                .searchable(text: $query, placement: .sidebar, prompt: "Search")
            }
        }
        .task(id: query) {
            let q = query.trimmingCharacters(in: .whitespaces)
            guard q.count >= 2 else { hits = nil; return }
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            hits = await Task.detached { Store.search(q) }.value
        }
        .onChange(of: model.scope) { query = "" }
        .onExitCommand { if model.selecting { model.selecting = false } else if model.settingsOpen { model.settingsOpen = false } else if model.openReport != nil { model.openReport = nil } else { model.selected = nil } }  // Esc: stop selecting, close Settings, a report, or back to the home or folder page
        .onAppear {
            visibility = sidebarOpen ? .all : .doubleColumn
            model.openMain = { openWindow(id: "main") }
        }
        .onChange(of: visibility) { sidebarOpen = visibility == .all }
        .background(WindowAccessor { Panels.shared.mainWindow = $0 })
        .overlay(alignment: .bottom) {
            if let t = model.toast {
                Text(t).padding(.horizontal, 14).padding(.vertical, 9)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .padding(.bottom, 70).onTapGesture { model.toast = nil }
            }
        }
        .frame(minWidth: 900, minHeight: 560)
        .sheet(isPresented: $model.showSetup) { SetupView().environmentObject(model).interactiveDismissDisabled() }
    }
}

struct WindowAccessor: NSViewRepresentable {
    let found: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { found(v.window) }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) { DispatchQueue.main.async { found(v.window) } }
}

// MARK: sidebar and list

struct Sidebar: View {
    @EnvironmentObject var model: Model
    let searching: Bool

    var body: some View {
        List(selection: Binding<Scope?>(get: { searching || model.settingsOpen ? nil : model.scope }, set: { if let s = $0 { model.scope = s; model.selected = nil } })) {
            Section("Library") {
                ForEach(Scope.library, id: \.name) { l in
                    Label(l.name, systemImage: l.symbol).badge(model.meetings.filter(l.scope.contains).count).tag(l.scope)
                        .contentShape(Rectangle()).simultaneousGesture(TapGesture().onEnded { model.scope = l.scope; model.selected = nil })
                }
            }
            Section {
                // Meetings in no folder; dropping one here takes it out of its folders.
                Label("No Folder", systemImage: "tray.and.arrow.down").badge(model.meetings.filter(Scope.unfiled.contains).count).tag(Scope.unfiled)
                    .dropDestination(for: String.self) { ids, _ in model.moveToFolder(ids, nil); return true }
                    .contentShape(Rectangle()).simultaneousGesture(TapGesture().onEnded { model.scope = .unfiled; model.selected = nil })
                // A tree, always open, drawn like the `tree` command: subfolders indented under their folder, joined by thin lines.
                let all = model.folders
                ForEach(all, id: \.name) { f in
                    Label { Text(folderLeaf(f.name)) } icon: { Text(model.folderEmoji[f.name] ?? "📁").scaleEffect(0.85) }  // emoji draw bigger than the symbols above
                        .padding(.leading, CGFloat(folderDepth(f.name)) * 16)
                        .background(TreeLines(guides: treeGuides(f.name, in: all.map(\.name))).stroke(Color.secondary.opacity(0.4), lineWidth: 1))
                    .badge(f.count).tag(Scope.folder(f.name))
                    .dropDestination(for: String.self) { ids, _ in model.moveToFolder(ids, f.name); return true }  // meetings dragged from the list move here
                    .contentShape(Rectangle()).simultaneousGesture(TapGesture().onEnded { model.scope = .folder(f.name); model.selected = nil })
                    .overlay(RightClick {
                        let menu = NSMenu()
                        menu.addItem(ActionItem("New Subfolder...") { model.newFolderParent = f.name; creating = true })
                        menu.addItem(ActionItem("Rename...") { newName = folderLeaf(f.name); renaming = f.name })
                        menu.addItem(ActionItem("Folder Settings...") { model.scope = .folder(f.name); model.selected = nil; model.folderSettings = f.name })
                        menu.addItem(.separator())
                        menu.addItem(ActionItem("Delete Folder...") { [model] in model.deleteFolder(f.name) })
                        return menu
                    })
                }
            } header: {
                Text("Folders")
            }
        }
        // Like Notes: "New Folder" at the bottom of the sidebar.
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 0) {
                Button { creating = true } label: { Label("New Folder", systemImage: "plus.circle").frame(maxWidth: .infinity) }
                    .help("Make a folder for meetings")
                    .popover(isPresented: $creating, arrowEdge: .top) { NewFolder(parent: model.newFolderParent) }
                    .onChange(of: creating) { if !creating { model.newFolderParent = nil } }
                Divider().frame(height: 14)
                Button { model.settingsOpen = true } label: { Label("Settings", systemImage: "gearshape").frame(maxWidth: .infinity) }
                    .foregroundStyle(model.settingsOpen ? Color.accentColor : .secondary)
                    .help("Settings (Command-Comma)")
            }
            .buttonStyle(.borderless).foregroundStyle(.secondary)
            .padding(.vertical, 10)
        }
        .alert("Rename Folder", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") { if let f = renaming { model.renameFolder(f, to: newName) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("Its subfolders, meetings and reports keep their place.")
        }
    }

    @State var creating = false
    @State var renaming: String?  // the folder whose new name is being typed
    @State var newName = ""
}

/// The `tree` command's lines left of a subfolder in the sidebar (see treeGuides): "│" for ancestors that go on, "├" or "└" for itself.
/// One level is 16 pt, the icon's centre 9 pt into it; lines reach a little past the row so they join across the gaps between rows.
struct TreeLines: Shape {
    let guides: [Bool]
    func path(in r: CGRect) -> Path {
        var p = Path()
        let ext: CGFloat = 9, mid = r.midY
        for (k, down) in guides.enumerated() {
            let x = CGFloat(k) * 16 + 9
            if k == guides.count - 1 {
                p.move(to: CGPoint(x: x, y: r.minY - ext)); p.addLine(to: CGPoint(x: x, y: down ? r.maxY + ext : mid))
                p.move(to: CGPoint(x: x, y: mid)); p.addLine(to: CGPoint(x: x + 6, y: mid))
            } else if down {
                p.move(to: CGPoint(x: x, y: r.minY - ext)); p.addLine(to: CGPoint(x: x, y: r.maxY + ext))
            }
        }
        return p
    }
}

/// Name, an emoji (random; click it for another), where it goes, and how its reports are written, for a new folder.
struct NewFolder: View {
    @EnvironmentObject var model: Model
    @Environment(\.dismiss) var dismiss
    @State var name = ""
    @State var emoji = randomFolderEmoji()
    @State var parent: String?  // nil: top level
    @State var period = ReportPeriod.week
    @State var template: String?  // nil: the default template

    init(parent: String? = nil) { _parent = State(initialValue: parent) }

    var full: String { let n = name.trimmingCharacters(in: .whitespaces); return parent.map { "\($0)/\(n)" } ?? n }
    var taken: Bool { model.folderExists(full) }
    var blank: Bool { name.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(parent == nil ? "New Folder" : "New Subfolder").font(.headline)
            // The emoji and the name on their own row; below, one column of labels and one of menus, all left-aligned at the same width.
            HStack(spacing: 10) {
                Button { emoji = randomFolderEmoji(avoiding: [emoji]) } label: {
                    Text(emoji).font(.system(size: 20)).frame(width: 32, height: 32).background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain).help("Another emoji")
                TextField("Name", text: $name).textFieldStyle(.roundedBorder).onSubmit(create)
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                if !model.folders.isEmpty {
                    GridRow {
                        Text("Inside").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                        Picker("Inside", selection: $parent) {
                            Text("Top level").tag(String?.none)
                            Divider()
                            ForEach(model.folders, id: \.name) { f in
                                Text(String(repeating: "    ", count: folderDepth(f.name)) + "\(model.folderEmoji[f.name] ?? "📁") \(folderLeaf(f.name))").tag(Optional(f.name))
                            }
                        }
                        .labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                GridRow {
                    Text("Reports for").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    Picker("Reports for", selection: $period) {
                        ForEach(ReportPeriod.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                }
                GridRow {
                    Text("Template").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    Picker("Template", selection: $template) {
                        Text("\(model.library.defaultTemplate.label) \u{2605}").tag(String?.none)
                        Divider()
                        ForEach(model.library.all) { t in Text(t.label).tag(Optional(t.id)) }
                    }
                    .labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if taken { Text("There is already a folder with this name here.").font(.caption).foregroundStyle(.red) }
            if name.contains("/") { Text("A slash is not allowed in a folder name.").font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create", action: create).keyboardShortcut(.defaultAction).disabled(blank || taken || name.contains("/"))
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    func create() {
        guard !blank, !taken, !name.contains("/") else { return }
        model.createFolder(name, emoji: emoji, parent: parent)
        let n = "\(parent.map { "\($0)/" } ?? "")\(name.trimmingCharacters(in: .whitespaces))"
        if period != .week { model.setReportPeriod(n, period) }
        if let template { model.setFolderTemplate(n, template) }
        dismiss()
    }
}

/// The emojis to pick from for a folder, and Shuffle.
struct EmojiPicker: View {
    let current: String
    var emojis = folderEmojis
    let pick: (String) -> Void
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 4), count: 6), spacing: 4) {
                ForEach(emojis, id: \.self) { e in
                    Button { pick(e); dismiss() } label: {
                        Text(e).font(.system(size: 20)).frame(width: 34, height: 34)
                            .background(e == current ? Color.accentColor.opacity(0.25) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                }
            }
            Button { pick(emojis.filter { $0 != current }.randomElement() ?? current); dismiss() } label: { Label("Shuffle", systemImage: "shuffle") }
        }
        .padding(12)
    }
}

struct MeetingList: View {
    @EnvironmentObject var model: Model
    let hits: [SearchHit]?
    let query: String

    var folder: String? { if case let .folder(f) = model.scope { f } else { nil } }
    var rows: [MeetingRow] { model.meetings.filter(model.scope.contains) }

    /// The rows (newest first) in runs of one day, under "Today", "Yesterday", "Monday, 28 Sep".
    var days: [(day: String, rows: [MeetingRow])] {
        var out: [(day: String, rows: [MeetingRow])] = []
        for m in rows {
            let d = dayHeading(meetingDate(m.id))
            if out.last?.day == d { out[out.count - 1].rows.append(m) } else { out.append((d, [m])) }
        }
        return out
    }

    var body: some View {
        List(selection: $model.selected) {
            if let hits {
                ForEach(hits) { h in
                    if ticking { tickRow(MeetingRowView(id: h.id, snippet: h.snippet, query: query, showDay: true), h.id) }
                    else { MeetingRowView(id: h.id, snippet: h.snippet, query: query, showDay: true).card(model.selected == h.id).tag(h.id).draggable(h.id).overlay(RightClick { rowMenu(h.id) }) }
                }
            } else {
                ForEach(days, id: \.day) { g in
                    Section {
                        ForEach(g.rows) { m in
                            if ticking {
                                tickRow(MeetingRowView(id: m.id), m.id)
                            } else {
                                MeetingRowView(id: m.id).card(model.selected == m.id).tag(m.id).draggable(m.id)  // drop it on a folder in the sidebar
                                    .overlay(RightClick { rowMenu(m.id) })
                            }
                        }
                    } header: {
                        Text(g.day).font(.system(size: 13, weight: .bold)).foregroundStyle(.primary)
                    }
                }
            }
        }
        // One menu for the whole list (not per row): macOS then marks the right-clicked row with its usual thin outline, like Finder.

        .overlay {
            if hits?.isEmpty ?? rows.isEmpty {
                if hits != nil { Placeholder(symbol: "magnifyingglass", title: "No results", text: "Nothing in titles, notes, summaries or transcripts matches.") }
                else if folder != nil { Placeholder(symbol: "folder", title: "No meetings yet", text: "Drag a meeting here from another list, or file it with a right click.") }
                else { Placeholder(symbol: "tray", title: "No meetings", text: model.scope == .all ? "Click New to record your first meeting." : "Meetings show up here as you record them.") }
            }
        }
        .onDeleteCommand { if model.selecting { model.deleteMeetings(model.picked.intersection(hits?.map(\.id) ?? rows.map(\.id))) } else if let id = model.selected { model.delete(id) } }  // Delete key: the ticked meetings, else the selected one
        .scrollContentBackground(.hidden).background(paper)  // the same soft surface as the page, not a glaring white column
        .safeAreaInset(edge: .bottom) {
            if model.selecting { SelectionBar(ids: hits?.map(\.id) ?? rows.map(\.id)).padding(14) }
            else if let folder, hits == nil, !rows.isEmpty { ReportBar(folder: folder).padding(14) }
            else if Model.scopeReports[model.scope] != nil, hits == nil, !rows.isEmpty { ScopeReportBar(scope: model.scope).padding(14) }
        }
        .navigationTitle(hits != nil ? "Search" : folderLeaf(model.scope.name))
        .toolbar {
            if #available(macOS 26.0, *) { ToolbarSpacer(.flexible) }
            // Right corner of the list column: one click starts a recording.
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .primaryAction) { HStack(spacing: 8) { SelectButton(); RecordButton() } }.sharedBackgroundVisibility(.hidden)  // their own capsules, not the toolbar's glass
            } else {
                ToolbarItem(placement: .primaryAction) { HStack(spacing: 8) { SelectButton(); RecordButton() } }
            }
        }
    }
}

extension MeetingList {
    /// Ticking: meetings to delete (Select), or meetings for this folder's report (Choose Meetings).
    var ticking: Bool { model.selecting || (folder != nil && model.choosing == folder) }

    /// A meeting card with a checkbox in front; clicking anywhere on it ticks it.
    func tickRow(_ row: MeetingRowView, _ id: String) -> some View {
        let on = model.selecting ? model.picked.contains(id) : model.chosen.contains(id)
        return HStack(spacing: 8) {
            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                .font(.title3).foregroundStyle(on ? Color.accentColor : .secondary)
            row.card(false)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if model.selecting { model.picked.formSymmetricDifference([id]) } else { model.chosen.formSymmetricDifference([id]) }
        }
    }

    /// The right-click menu of a meeting: folders (ticked where it is; No Folder takes it out of all) and Delete.
    func rowMenu(_ id: String) -> NSMenu {
        let menu = NSMenu()
        let folders = model.folders.map(\.name), tags = model.meetings.first { $0.id == id }?.tags ?? []
        let sub = NSMenu()
        let none = ActionItem("No Folder") { [model] in model.moveToFolder([id], nil) }
        none.state = tags.isEmpty ? .on : .off
        sub.addItem(none)
        sub.addItem(.separator())
        if folders.isEmpty {
            let hint = ActionItem("No folders yet: New Folder is at the bottom of the sidebar") {}
            hint.isEnabled = false
            sub.addItem(hint)
        }
        for f in folders {
            let item = ActionItem("\(model.folderEmoji[f] ?? "📁") \(folderLeaf(f))") { [model] in model.toggleFolder(id, f) }
            item.state = tags.contains(f) ? .on : .off
            item.indentationLevel = folderDepth(f)
            sub.addItem(item)
        }
        let folderItem = NSMenuItem(title: "Folders", action: nil, keyEquivalent: "")
        folderItem.submenu = sub
        menu.addItem(folderItem)
        menu.addItem(.separator())
        menu.addItem(ActionItem("Select Meetings...") { [model] in if !model.selecting { model.selecting = true }; model.picked.insert(id) })
        let delete = ActionItem("Delete Meeting...") { [model] in model.delete(id) }
        delete.isEnabled = !(id == model.activeId && model.busy)
        menu.addItem(delete)
        menu.autoenablesItems = false
        return menu
    }
}

/// Right click: pops up an AppKit menu. SwiftUI's own context menus make the List draw a blue ring around the row, which looks off here.
/// Only right clicks land on this view; everything else goes through to the row.
struct RightClick: NSViewRepresentable {
    let menu: () -> NSMenu
    func makeNSView(context: Context) -> RightClickView { RightClickView() }
    func updateNSView(_ v: RightClickView, context: Context) { v.makeMenu = menu }

    final class RightClickView: NSView {
        var makeMenu: () -> NSMenu = { NSMenu() }
        override func hitTest(_ p: NSPoint) -> NSView? {
            let e = NSApp.currentEvent
            return e?.type == .rightMouseDown || (e?.type == .leftMouseDown && e?.modifierFlags.contains(.control) == true) ? super.hitTest(p) : nil
        }
        override func rightMouseDown(with e: NSEvent) { NSMenu.popUpContextMenu(makeMenu(), with: e, for: self) }
        override func mouseDown(with e: NSEvent) { NSMenu.popUpContextMenu(makeMenu(), with: e, for: self) }  // Control-click
    }
}

/// A menu item that runs a closure.
final class ActionItem: NSMenuItem {
    private let run: () -> Void
    init(_ title: String, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { run() }
}

/// Red text on a soft red fill (New, End): darker in light mode so it reads.
let softRed = Color(light: .init(srgbRed: 0.79, green: 0.16, blue: 0.12, alpha: 1), dark: .init(srgbRed: 1, green: 0.41, blue: 0.38, alpha: 1))
/// The transcript popup's body, under its white (dark grey) header bar.
let popupColor = Color(light: .init(srgbRed: 0.961, green: 0.961, blue: 0.969, alpha: 1), dark: .init(srgbRed: 0.137, green: 0.137, blue: 0.145, alpha: 1))

/// A card's surface on the soft page: white in light mode, a lifted grey in dark mode.
let cardColor = Color(light: .white, dark: NSColor(srgbRed: 0.165, green: 0.165, blue: 0.173, alpha: 1))

extension View {
    /// A meeting row as a card with a little air around it; the selected one shows the list's own selection instead.
    func card(_ selected: Bool) -> some View {
        background(selected ? Color.clear : cardColor, in: RoundedRectangle(cornerRadius: 10))
            .listRowInsets(EdgeInsets(top: 3, leading: 0, bottom: 3, trailing: 0))
            .listRowSeparator(.hidden)
    }
}

/// A meeting as a card: its folder's emoji in a rounded square (a waveform when it is in no folder), the title, and the time and length.
/// In a folder the emoji is the most specific folder of the meeting inside it, so a subfolder's meetings show the subfolder's.
struct MeetingRowView: View {
    @EnvironmentObject var model: Model
    let id: String
    var snippet: String?
    var query = ""
    var showDay = false  // search results are not grouped by day

    var body: some View {
        let row = model.meetings.first { $0.id == id }, title = row?.title, tags = row?.tags ?? []
        let folder: String? = switch model.scope {
            case let .folder(f): tags.filter { isIn([$0], f) }.max { folderDepth($0) < folderDepth($1) }
            default: tags.first
        }
        let d = meetingDate(id), mins = model.lengths[id] ?? 0
        HStack(spacing: 10) {
            Group {
                if let folder { Text(model.folderEmoji[folder] ?? "📁").font(.system(size: 17)) }
                else { Image(systemName: "waveform").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary) }
            }
            .frame(width: 30, height: 30)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .help(tags.map(folderPath).joined(separator: ", "))
            VStack(alignment: .leading, spacing: 3) {
                Text(title ?? fallbackTitle(id)).font(.system(size: 13, weight: .semibold)).foregroundStyle(title == nil ? .secondary : .primary).lineLimit(1)
                HStack(spacing: 4) {
                    Text((showDay ? "\(shortDay(d)), " : "") + hm(d) + (mins > 0 ? " · \(mins) min" : "")).monospacedDigit()
                    if model.activeId == id && model.status == .recording {
                        Text("·"); Circle().fill(model.callEnding ? .orange : .red).frame(width: 6, height: 6); Text(model.callEnding ? "Finishing" : "Recording")
                    } else if model.activeId == id && model.busy {
                        Text("· Writing summary")
                    }
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
                if let snippet { Text(highlighted(snippet)).font(.system(size: 11)).lineLimit(3) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
    }

    func highlighted(_ s: String) -> AttributedString {
        var a = AttributedString(s)
        var from = a.startIndex
        while let r = a[from...].range(of: query, options: .caseInsensitive) {
            a[r].backgroundColor = .yellow.opacity(0.45)
            from = r.upperBound
        }
        return a
    }
}

// MARK: detail

struct Detail: View {
    @EnvironmentObject var model: Model

    var body: some View {
        let folder: String? = if case let .folder(f) = model.scope { f } else { nil }
        let key = model.selected.map { "m:\($0)" } ?? folder.map { "f:\($0)" } ?? "all"
        VStack(spacing: 0) {
            if let id = model.selected {
                MeetingView(id: id).id(id)
            } else if let r = model.openReport {
                ReportView(open: r).id(r)
            } else if let folder {
                FolderView(folder: folder).id(folder)
            } else {
                HomeView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(paper)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)  // else a white band sits above the grey page
        .toolbar {
            // A detail toolbar that never changes: items that come and go make macOS lay the whole toolbar out again (the list's record
            // button flickers), and without one of its own the detail's toolbar merges with the list's. Back is always there, greyed out
            // when there is nowhere to go.
            // Back at the left edge of the page, right above its title; the page's own buttons at the right.
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .automatic) { BackButton() }.sharedBackgroundVisibility(.hidden)
                ToolbarSpacer(.flexible)
                ToolbarItem(placement: .primaryAction) { PageActions() }.sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .navigation) { BackButton() }
                ToolbarItem(placement: .primaryAction) { PageActions() }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if model.selected != nil || !model.meetings.isEmpty {
                ChatBox(key: key, label: model.selected != nil ? "Ask about this meeting" : folder.map { "Ask about meetings in \(folderLeaf($0))" } ?? "Ask across all meetings").id(key)
            }
        }
    }
}

/// Back to the previous page (folder, meeting, report, Settings), like a browser. Command-[ too, from the Go menu.
struct BackButton: View {
    @EnvironmentObject var model: Model
    var body: some View {
        Button { model.back() } label: { Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold)) }
            .buttonStyle(BarButton(round: true))
            .disabled(model.history.isEmpty)
            .help("Back (Command-[)")
    }
}

/// The list's "New" button: a soft red capsule with a red dot, like the home page's New Meeting. Greyed out while a meeting is busy.
struct RecordButton: View {
    @EnvironmentObject var model: Model
    var body: some View {
        Button { model.startNew() } label: {
            HStack(spacing: 6) {
                Circle().fill(model.busy ? Color.secondary : .red).frame(width: 8, height: 8)
                Text("New").font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(model.busy ? Color.secondary : softRed)
            .padding(.leading, 10).padding(.trailing, 12).frame(height: 30)
            .background(Color.red.opacity(model.busy ? 0.06 : 0.15), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(model.busy)
        .help("Record a new meeting (Command-N)")
    }
}

/// The list's Select button: tick meetings to delete several at once. Highlighted while ticking; click again to stop.
struct SelectButton: View {
    @EnvironmentObject var model: Model
    var body: some View {
        Button { model.selecting.toggle() } label: { Image(systemName: model.selecting ? "checkmark.circle.fill" : "checkmark.circle") }
            .buttonStyle(BarButton(tint: model.selecting ? .accentColor : nil, round: true))
            .disabled(model.meetings.isEmpty && !model.selecting)
            .help(model.selecting ? "Stop selecting" : "Select meetings, to delete several at once")
    }
}

/// Under the list while ticking meetings: tick all or none of the shown ones, delete the ticked ones, or stop.
struct SelectionBar: View {
    @EnvironmentObject var model: Model
    let ids: [String]  // the meetings the list shows

    var body: some View {
        // Only what the list shows counts: ticks hidden by a search since are never deleted unseen.
        let shown = model.picked.intersection(ids), all = !ids.isEmpty && shown.count == Set(ids).count, n = shown.count
        HStack(spacing: 8) {
            Button { if all { model.picked.subtract(ids) } else { model.picked.formUnion(ids) } } label: { Text(all ? "None" : "All").pill() }
                .help(all ? "Untick every meeting in the list" : "Tick every meeting in the list")
            Button { model.deleteMeetings(shown) } label: {
                Label(n == 0 ? "Delete" : "Delete (\(n))", systemImage: "trash").foregroundStyle(n == 0 ? Color.secondary : .red).pill()
            }
            .disabled(n == 0)
            .help(n == 0 ? "Tick the meetings to delete in the list" : "Move the ticked meetings to the Trash")
            Button { model.selecting = false } label: { Text("Done").pill() }.help("Stop selecting (Esc)")
        }
        .buttonStyle(.plain)
        .lineLimit(1)
    }
}

/// The main call to action on the home page. While a meeting records it leads back to that meeting instead.
struct BigRecordButton: View {
    @EnvironmentObject var model: Model

    var body: some View {
        Button { if model.busy { model.selected = model.activeId } else { model.startNew() } } label: {
            HStack(spacing: 10) {
                Circle().fill(.red).frame(width: 14, height: 14)
                Text(model.status == .recording ? "Back to the Recording" : model.busy ? "Back to the Meeting" : "New Meeting")
            }
            .font(.title2.weight(.semibold))
            .padding(.horizontal, 22).padding(.vertical, 12)
            .background(Color.red.opacity(0.12), in: Capsule())
            .overlay(Capsule().stroke(Color.red.opacity(0.35)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(model.busy ? "Open the meeting that is being recorded" : "Start recording a new meeting")
    }
}

struct HomeView: View {
    @EnvironmentObject var model: Model

    var body: some View {
        VStack(spacing: 14) {
            if model.meetings.isEmpty {
                Text("Welcome to Waffle").font(.largeTitle.bold())
                Text("Waffle listens to your calls and writes the notes. Audio is never stored and never leaves this Mac.").foregroundStyle(.secondary)
                BigRecordButton()
                VStack(alignment: .leading, spacing: 6) {
                    Text("• Join a call in Zoom, Teams, Meet or Slack, and Waffle offers to record it.")
                    Text("• The live transcript appears as people speak.")
                    Text("• When the call ends you get a summary, and you can ask questions about it.")
                }
                .foregroundStyle(.secondary).padding(.top, 8)
            } else {
                Text("Ask your meetings").font(.largeTitle.bold())
                Text("Decisions, owners, dates: ask about anything that was said in any meeting.").foregroundStyle(.secondary)
                BigRecordButton().padding(.top, 18)
            }
        }
        .multilineTextAlignment(.center)
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A folder's page: its name, a few numbers about its meetings, and the reports written so far. The folder's settings (emoji, report
/// period and template) are behind the gear; a new folder gets them in New Folder.
struct FolderView: View {
    @EnvironmentObject var model: Model
    let folder: String
    @State var reports: [Report] = []
    @State var minutes: [String: Int] = [:]  // length of each meeting in the folder

    var meetings: [MeetingRow] { model.meetings.filter { isIn($0.tags, folder) } }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Text(model.folderEmoji[folder] ?? "📁").font(.system(size: 26)).frame(width: 40, height: 40)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(folderLeaf(folder)).font(.title2.bold())
                        if folderDepth(folder) > 0 { Text("in \(folderPath(String(folder.prefix(upTo: folder.lastIndex(of: "/")!))))").font(.callout).foregroundStyle(.secondary) }
                    }
                    Spacer()
                }
            }
            Section { stats }
            Section("Reports") {
                if model.writingUpdate.contains(folder) {
                    Button { model.openReport = OpenReport(folder: folder) } label: {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Writing a report..."); Spacer() }.padding(.vertical, 8).contentShape(Rectangle()).padding(.vertical, -8)
                    }
                    .buttonStyle(.plain)
                }
                if reports.isEmpty && !model.writingUpdate.contains(folder) {
                    Text("No reports yet. Report is under the meeting list.").foregroundStyle(.secondary)
                }
                ForEach(reports) { r in
                    Button { model.openReport = OpenReport(folder: folder, id: r.id) } label: {
                        HStack {
                            Text(r.title)
                            Spacer()
                            Text("\(shortDay(meetingDate(r.id))), \(hm(meetingDate(r.id)))").foregroundStyle(.secondary).monospacedDigit()
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 8).contentShape(Rectangle()).padding(.vertical, -8)  // the whole row clicks, its padding too
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Delete Report...", role: .destructive) {
                            if confirm("Delete this report?", "\u{201C}\(r.title)\u{201D} is moved to the Trash.", "Delete") { Store.deleteReport(r.id); model.reload() }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .sheet(isPresented: Binding(get: { model.folderSettings == folder }, set: { if !$0 { model.folderSettings = nil } })) { FolderSettings(folder: folder) }
        .task(id: model.revision) {
            reports = Store.reports(folder)
            let ids = meetings.map(\.id)
            minutes = await Task.detached { Dictionary(uniqueKeysWithValues: ids.map { id in let l = Store.lines(id); return (id, l.count > 1 ? (l.last!.t - l.first!.t) / 60000 : 0) }) }.value
        }
    }

    /// Headline numbers, then minutes recorded per week over the last 8 weeks (hover a bar for its week).
    var stats: some View {
        let ms = meetings, total = minutes.values.reduce(0, +)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 0) {
                Stat(symbol: "person.2.wave.2", value: "\(ms.count)", label: ms.count == 1 ? "Meeting" : "Meetings")
                Stat(symbol: "clock", value: duration(total), label: "Recorded")
                Stat(symbol: "timer", value: ms.isEmpty ? "-" : duration(total / ms.count), label: "Average")
                Stat(symbol: "calendar", value: ms.first.map { shortDay(meetingDate($0.id)) } ?? "-", label: "Last Meeting")
            }
            Divider()
            WeekChart(bars: weekBars(ms.map(\.id), minutes))
        }
        .padding(.vertical, 6)
    }
}

/// Meetings and minutes of one week (the week's first day).
struct WeekBar: Identifiable { let week: Date; var count = 0; var minutes = 0; var id: Date { week } }

/// The last `n` weeks up to this one, oldest first, with the meetings that fall in each.
func weekBars(_ ids: [String], _ minutes: [String: Int], n: Int = 8, now: Date = Date()) -> [WeekBar] {
    let cal = Calendar.current, thisWeek = cal.dateInterval(of: .weekOfYear, for: now)!.start
    var bars = (0..<n).reversed().map { WeekBar(week: cal.date(byAdding: .weekOfYear, value: -$0, to: thisWeek)!) }
    for id in ids {
        guard let w = cal.dateInterval(of: .weekOfYear, for: meetingDate(id))?.start, let i = bars.firstIndex(where: { $0.week == w }) else { continue }
        bars[i].count += 1; bars[i].minutes += minutes[id] ?? 0
    }
    return bars
}

/// "25 min", "1 h 5 min".
func duration(_ m: Int) -> String { m >= 60 ? "\(m / 60) h\(m % 60 > 0 ? " \(m % 60) min" : "")" : "\(m) min" }

/// Minutes recorded per week, one accent-coloured bar each; hovering a week shows its numbers in the caption and dims the other bars.
struct WeekChart: View {
    let bars: [WeekBar]
    @State var hovered: String?  // the hovered week's label

    var body: some View {
        let sel = hovered.flatMap { h in bars.first { shortDay($0.week) == h } }
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Time recorded per week").font(.subheadline.weight(.semibold))
                Spacer()
                Text(sel.map { "Week of \(shortDay($0.week)): \($0.count) meeting\($0.count == 1 ? "" : "s"), \(duration($0.minutes))" } ?? "Last 8 weeks")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Chart(bars) { b in
                BarMark(x: .value("Week", shortDay(b.week)), y: .value("Minutes", b.minutes), width: .ratio(0.55))  // one label per bar, in the app's "29 Sep"
                    .cornerRadius(4)
                    .foregroundStyle(Color.accentColor.opacity(sel == nil || sel?.week == b.week ? 1 : 0.35))
            }
            .chartXSelection(value: $hovered)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                    AxisValueLabel { if let m = v.as(Int.self) { Text(m >= 60 && m % 60 == 0 ? "\(m / 60) h" : "\(m) m") } }
                }
            }
            .frame(height: 130)
        }
    }
}

/// One headline number, Fitness style: a small symbol and label over a big rounded number.
struct Stat: View {
    let symbol: String
    let value: String
    let label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(label, systemImage: symbol).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Text(value).font(.system(.title2, design: .rounded).weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A folder's settings, in a sheet: emoji, and the period and template of its reports.
struct FolderSettings: View {
    @EnvironmentObject var model: Model
    @Environment(\.dismiss) var dismiss
    let folder: String
    @State var pickingEmoji = false
    @State var name = ""

    var parent: String? { folder.lastIndex(of: "/").map { String(folder[..<$0]) } }
    var newName: String { name.trimmingCharacters(in: .whitespaces) }
    /// The name was changed to one that can be used: not empty, no slash, not another folder's.
    var renamed: Bool {
        let full = parent.map { "\($0)/\(newName)" } ?? newName
        return !newName.isEmpty && !newName.contains("/") && full != folder && (!model.folderExists(full) || full.lowercased() == folder.lowercased())
    }

    var body: some View {
        let lib = model.library, chosen = lib.folders[folder]
        VStack(spacing: 0) {
            Form {
                Section {
                    HStack(spacing: 12) {
                        Button { pickingEmoji = true } label: {
                            Text(model.folderEmoji[folder] ?? "📁").font(.system(size: 26)).frame(width: 40, height: 40)
                                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
                        }
                        .buttonStyle(.plain).help("Change the emoji")
                        .popover(isPresented: $pickingEmoji) { EmojiPicker(current: model.folderEmoji[folder] ?? "") { model.setFolderEmoji(folder, $0) } }
                        VStack(alignment: .leading, spacing: 2) {
                            TextField("Name", text: $name).textFieldStyle(.plain).font(.title3.bold()).onSubmit(done)
                            if let parent { Text("in \(folderPath(parent))").font(.callout).foregroundStyle(.secondary) }
                        }
                    }
                } footer: {
                    if newName.contains("/") { Text("A slash is not allowed in a folder name.").font(.caption).foregroundStyle(.red) }
                    else if !newName.isEmpty && newName != folderLeaf(folder) && !renamed { Text("There is already a folder with this name here.").font(.caption).foregroundStyle(.red) }
                }
                Section {
                    Picker("Period", selection: Binding(get: { model.reportPeriod(folder) }, set: { model.setReportPeriod(folder, $0) })) {
                        ForEach(ReportPeriod.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Template", selection: Binding(get: { chosen }, set: { model.setFolderTemplate(folder, $0) })) {
                        Text("\(lib.defaultTemplate.label) \u{2605}").tag(String?.none)  // the star: the default template, whichever it is
                        Divider()
                        ForEach(lib.all) { t in Text(t.label).tag(Optional(t.id)) }
                    }
                } header: {
                    Text("Reports")
                } footer: {
                    Text("Report, under this folder's meetings, writes one report over the meetings of this period in this template.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                Button(role: .destructive) {
                    let f = folder
                    dismiss()
                    DispatchQueue.main.async { model.deleteFolder(f) }  // the alert after the sheet is gone
                } label: { Label("Delete Folder...", systemImage: "trash") }
                .foregroundStyle(.red).help("Delete this folder; its meetings stay")
                Button("Manage Templates...") { dismiss(); model.settingsOpen = true }.help("Add or change templates in Settings")
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { name = folderLeaf(folder) }
    }

    /// Closes the sheet; a changed name renames the folder (and reopens its page under the new name).
    func done() {
        let f = folder, n = newName, rename = renamed
        dismiss()
        if rename { DispatchQueue.main.async { model.renameFolder(f, to: n) } }
    }
}

// MARK: meeting

enum Tab: String, CaseIterable { case transcript = "Transcript", notes = "Notes", summary = "Summary" }

struct MeetingView: View {
    @EnvironmentObject var model: Model
    @ObservedObject var live = Model.shared.live
    let id: String
    @State var tab = Tab.summary
    @State var summary: String?
    @State var diskLines: [Line] = []
    @State var notes = ""
    @State var savedNotes = ""
    @State var copied = false
    @State var speakerMeta: [String: String] = [:]
    @State var usedTemplate: String?  // the template of the current summary (nil: written before templates, so the default)

    var active: Bool { model.activeId == id }
    var status: Status { active ? model.status : .done }
    var lines: [Line] { active ? live.lines : diskLines }
    /// Names of the voices: while recording also the ones the call window settled.
    var names: [String: String] { active ? live.names : speakerMeta }
    var tags: [String] { model.meetings.first { $0.id == id }?.tags ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(model.title(id)).font(.title.bold()).textSelection(.enabled)
                Spacer()
            }
            meta
            if model.interrupted(id) {
                Label("Recording stopped because Waffle quit during the meeting. Continue recording, or make a summary from what was captured.", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).symbolRenderingMode(.multicolor)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            }
            HStack {
                Picker("", selection: $tab) { ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) } }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
                if tab == .summary {
                    if status == .done && !model.busy && !lines.isEmpty {
                        // Write it again, with the same template or another one. The button shows the template of the current summary.
                        RegenerateButton(used: model.library.template(usedTemplate), first: summary == nil) { model.regenerate(id, template: $0) }
                    }
                    if let summary {  // Copy stays at the right edge
                        Button(copied ? "Copied" : "Copy") { copy(summary) }.help("Copy as rich text, ready for Slack or email")
                    }
                }
                if tab == .transcript && !lines.isEmpty {
                    Button(copied ? "Copied" : "Copy") { copyTranscript() }.help("Copy the transcript as \u{201C}Who: what they said\u{201D}, one line per turn")
                }
            }
            .padding(.top, 4)
            Divider()
            switch tab {
            case .summary: SummaryView(text: summary, empty: status == .recording ? Placeholder(symbol: "text.append", title: "Summary after the meeting", text: "Waffle writes the notes when the meeting ends.")
                : [.finalizing, .summarizing].contains(status) ? Placeholder(symbol: "", title: "Writing the summary", text: "The AI is turning the transcript and your notes into the summary. This takes about a minute.", busy: true)
                : lines.isEmpty ? Placeholder(symbol: "waveform.slash", title: "Nothing to summarise", text: "Nothing was transcribed in this meeting.")
                : Placeholder(symbol: "doc.text", title: "No summary yet", text: "Make one with Make Summary above."))
            case .transcript: TranscriptView(lines: lines, typing: active && status == .recording ? live.hearing : [], empty: status == .recording ? Placeholder(symbol: "waveform", title: "Listening", text: "Text appears here a few seconds after people speak.") : Placeholder(symbol: "waveform.slash", title: "No transcript", text: "Nothing was transcribed in this meeting."), names: speakerNames(lines, names: names),
                                                delete: { model.confirmDeleteLine(id, $0) }, rename: { model.nameSpeaker(id, $0, $1) })
            case .notes:
                TextEditor(text: $notes).font(.body).scrollContentBackground(.hidden)
                    .overlay(alignment: .topLeading) {
                        if notes.isEmpty { Text("Jot down what matters to you. The summary is built around your notes.").foregroundStyle(.tertiary).padding(.leading, 5).allowsHitTesting(false) }
                    }
            }
        }
        .padding(.horizontal, 24).padding(.top, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle(model.title(id))
        .onAppear {
            load()
            notes = Store.notes(id); savedNotes = notes
            tab = status == .recording || summary == nil ? .transcript : .summary
        }
        .onChange(of: model.revision) { load() }
        // Live meeting: the transcript. When it ends and the notes are written: the summary.
        .onChange(of: status) { if status == .recording { tab = .transcript } }
        .onChange(of: summary) { old, new in if old == nil && new != nil && status == .done { tab = .summary } }
        .task(id: notes) {
            guard notes != savedNotes else { return }
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            Store.saveNotes(id, notes); savedNotes = notes
        }
        .onDisappear { if notes != savedNotes { Store.saveNotes(id, notes) } }
    }

    func load() {
        summary = Store.summary(id)
        speakerMeta = Store.speakers(id)
        usedTemplate = Store.meta(id)["template"] as? String
        if !active { diskLines = Store.lines(id) }
    }

    /// Date, length and the folders, as one quiet line. Folders are set by dragging the meeting onto one, or from its right-click menu.
    var meta: some View {
        let d = meetingDate(id), mins = lines.count > 1 ? (lines.last!.t - lines.first!.t) / 60000 : 0
        let folders = tags.map { "\(model.folderEmoji[$0] ?? "📁") \(folderPath($0))" }
        return Text(([ "\(longDate(id)), \(hm(d))" ] + (mins > 0 ? ["\(mins) min"] : []) + folders).joined(separator: "  ·  "))
            .foregroundStyle(.secondary).lineLimit(1)
    }

    func copy(_ text: String) {
        copyRich(text)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }

    func copyTranscript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcriptCopy(lines, names: names), forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }
}

/// The toolbar's right side, for whatever page is open: a meeting's recording controls, a report's Copy, a folder's settings. Pages close
/// with Back or Esc. It is one toolbar item that is always there (only its content changes), since items that come and go re-lay the toolbar out.
struct PageActions: View {
    @EnvironmentObject var model: Model
    @State var copied = false

    var body: some View {
        HStack(spacing: 10) {
            if let id = model.selected {
                MeetingActions(id: id)
            } else if let open = model.openReport {
                if !(open.id == nil && model.writingUpdate.contains(open.folder)), let r = open.id.map({ Store.report($0) }) ?? Store.reports(open.folder).first {
                    Button {
                        copyRich(r.text); copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    } label: { Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") }
                    .buttonStyle(BarButton())
                    .help("Copy as rich text, ready for Slack or email")
                }
            } else if case let .folder(f) = model.scope {
                Button { model.folderSettings = f } label: { Image(systemName: "gearshape") }
                    .buttonStyle(BarButton(round: true)).help("Folder settings: emoji, report period and template")
            }
        }
    }
}

/// The recording clock and End Meeting, or Resume Recording (and Make Summary for an interrupted meeting).
struct MeetingActions: View {
    @EnvironmentObject var model: Model
    let id: String
    var status: Status { model.activeId == id ? model.status : .done }

    var body: some View {
        HStack(spacing: 10) {
            switch status {
            case .recording:
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    StatusPill(elapsed(Int(Date().timeIntervalSince(meetingDate(id))))) { Circle().fill(model.callEnding ? .orange : .red).frame(width: 7, height: 7) }
                        .help(model.callEnding ? "The call ended: Waffle stops recording in a few seconds" : "Recording")
                }
                MicButton()
                Button { model.endMeeting() } label: { Label("End", systemImage: "stop.fill") }
                    .buttonStyle(BarButton(tint: .red)).help("Stop recording and write the notes")
            case .finalizing, .summarizing:
                StatusPill(status == .finalizing ? "Finishing" : "Writing notes") { ProgressView().controlSize(.mini) }.help(model.detail.prefix(1).uppercased() + model.detail.dropFirst())
            default:
                if model.interrupted(id) { StatusPill("Interrupted") { Circle().fill(.orange).frame(width: 7, height: 7) } }
                if !model.busy {
                    Button { model.resume(id) } label: { Label("Resume Recording", systemImage: "play.fill") }
                        .buttonStyle(BarButton()).help("Keep recording into this meeting")
                    if model.interrupted(id) { Button { model.regenerate(id) } label: { Label("Make Summary", systemImage: "sparkles") }.buttonStyle(BarButton(tint: .accentColor)) }
                }

            }
        }
        .fixedSize()  // the toolbar must not squeeze these
    }
}

/// Turns transcribing of your own microphone ("Me") off and on during a recording.
struct MicButton: View {
    @EnvironmentObject var model: Model
    var body: some View {
        Button { model.micMuted.toggle() } label: { Image(systemName: model.micMuted ? "mic.slash.fill" : "mic.fill") }
            .buttonStyle(BarButton(tint: model.micMuted ? .red : nil, round: true))
            .help(model.micMuted ? "Your microphone is not transcribed. Click to transcribe \u{201C}Me\u{201D} again." : "Stop transcribing your microphone (\u{201C}Me\u{201D}), for when you mostly listen. The call still hears you.")
    }
}

/// Two parts, like the Report button: Regenerate writes the summary again in the same template; the template's emoji next to it opens
/// the list to write it in another one. Both ask first.
struct RegenerateButton: View {
    @EnvironmentObject var model: Model
    let used: Template
    let first: Bool  // no summary yet: nothing to replace, so no question
    let run: (String) -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button { ask(used) } label: {
                Text(first ? "Make Summary" : "Regenerate").padding(.leading, 10).padding(.trailing, 8).padding(.vertical, 4).contentShape(Rectangle())
            }
            .help(first ? "Write the summary as \u{201C}\(used.name)\u{201D}" : "Write the summary again as \u{201C}\(used.name)\u{201D}")
            Divider().frame(height: 14)
            Menu {
                Section("Write as") {
                    ForEach(model.library.all) { t in
                        Button { ask(t) } label: { if t.id == used.id { Label(t.label, systemImage: "checkmark") } else { Text(t.label) } }
                    }
                }
            } label: {
                HStack(spacing: 3) { Text(used.emoji ?? "📝"); Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary) }
                    .padding(.leading, 7).padding(.trailing, 9).padding(.vertical, 4).contentShape(Rectangle())
            }
            .menuStyle(.button).menuIndicator(.hidden).fixedSize()
            .help("Template: \(used.name). Click for another one")
        }
        .buttonStyle(.plain)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.1)))
        .fixedSize()
    }

    /// The alert waits for the menu to close first: a modal opened while a menu is still tracking can swallow the click.
    func ask(_ t: Template) {
        DispatchQueue.main.async {
            if first || confirm("Write the summary again as \u{201C}\(t.name)\u{201D}?", "The AI writes a new summary from the transcript and your notes. The current one is replaced here (the old file stays in the meeting folder).", "Regenerate") { run(t.id) }
        }
    }
}

/// A toolbar status shaped like BarButton but not clickable: the recording time, "Writing notes", "Interrupted".
struct StatusPill<Lead: View>: View {
    let text: String
    let lead: Lead
    init(_ text: String, @ViewBuilder lead: () -> Lead) { self.text = text; self.lead = lead() }
    var body: some View {
        HStack(spacing: 6) { lead; Text(text).monospacedDigit() }
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 12).frame(height: 30)
            .background(Color.primary.opacity(0.09), in: Capsule())
    }
}

/// An empty or waiting page, centred, the macOS way: a symbol (or a spinner while something is being written), a title and a line of text.
struct Placeholder: View {
    let symbol: String
    let title: String
    let text: String
    var busy = false
    var body: some View {
        ContentUnavailableView {
            VStack(spacing: 10) {
                if busy { ProgressView() } else { Image(systemName: symbol).font(.system(size: 34, weight: .light)).foregroundStyle(.secondary) }
                Text(title).font(.title3.weight(.semibold))
            }
        } description: {
            Text(text)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)  // centred in whatever space the page leaves
    }
}

/// The toolbar's buttons, all one size and shape: 30 pt high, a capsule with a soft fill (a circle for an icon alone). `tint` colours the
/// text and the fill, for the few that must stand out (New, End Meeting).
struct BarButton: ButtonStyle {
    var tint: Color? = nil
    var round = false
    @Environment(\.isEnabled) var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(tint ?? .primary)
            .padding(.horizontal, round ? 0 : 12)
            .frame(width: round ? 30 : nil, height: 30)
            .background((tint ?? .primary).opacity(configuration.isPressed ? 0.2 : 0.09), in: Capsule())
            .contentShape(Capsule())
            .opacity(enabled ? 1 : 0.35)
    }
}

struct SummaryView: View {
    let text: String?
    let empty: Placeholder

    var body: some View {
        if let text { ScrollView { MarkdownBlocks(text: text).padding(.vertical, 8) } } else { empty }
    }
}

/// Summary Markdown as text: headings, nested bullets, bold. Does not scroll by itself.
struct MarkdownBlocks: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(blocks(text).enumerated()), id: \.offset) { i, b in
                switch b {
                case let .heading(t): Text(inline(t)).font(.title3.bold()).padding(.top, i == 0 ? 0 : 12)
                case let .bullet(level, t):
                    HStack(alignment: .firstTextBaseline, spacing: 7) { Text(level == 0 ? "•" : "◦").foregroundStyle(.secondary); Text(inline(t)) }
                        .padding(.leading, CGFloat(level) * 20)
                case let .paragraph(t): Text(inline(t))
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Rich text for Slack and email (bold, real nested lists) plus the Markdown as plain text.
func copyRich(_ text: String) {
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(summaryHTML(text), forType: .html)
    pb.setString(text, forType: .string)
}

/// The transcript as a chat, like Messages: "Me" on the right in accent-blue bubbles, the other voices on the left in grey ones. A run of
/// lines from one voice is one turn, headed by the name (click a told-apart voice to name it) and the time.
struct TranscriptView: View {
    let lines: [Line]
    let typing: Set<String>
    let empty: Placeholder
    var names: [String: String] = [:]
    var delete: (Line) -> Void = { _ in }
    var rename: (_ spk: String, _ name: String) -> Void = { _, _ in }

    /// One row per line, with the speaker's name and time over the first line of each run from the same source and voice. Rows, not
    /// runs, so the list stays lazy: a long monologue as one run was one huge row, built in full and slow to open.
    var rows: [(id: Int, line: Line, name: String, first: Bool)] {
        var out: [(id: Int, line: Line, name: String, first: Bool)] = []
        out.reserveCapacity(lines.count)
        for (i, l) in lines.enumerated() {
            let name = label(l, names)
            let first = out.last.map { $0.line.src != l.src || $0.name != name } ?? true
            out.append((i, l, name, first))
        }
        return out
    }

    var body: some View {
        if lines.isEmpty && typing.isEmpty { empty } else { chat }
    }

    var chat: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 3) {
                ForEach(rows, id: \.id) { r in
                    VStack(alignment: r.line.src == "mic" ? .trailing : .leading, spacing: 3) {
                        if r.first { TurnHeader(line: r.line, name: r.name, rename: rename).padding(.top, r.id == 0 ? 0 : 9) }
                        LineBubble(line: r.line, me: r.line.src == "mic", delete: delete)
                    }
                    .frame(maxWidth: .infinity, alignment: r.line.src == "mic" ? .trailing : .leading)
                }
                ForEach(["sys", "mic"].filter(typing.contains), id: \.self) { src in
                    HStack {
                        if src == "mic" { Spacer() }
                        TypingDots().padding(.horizontal, 14).padding(.vertical, 10).background(src == "mic" ? meBubble : themBubble, in: RoundedRectangle(cornerRadius: 16))
                            .foregroundStyle(src == "mic" ? Color.white : .secondary)
                        if src != "mic" { Spacer() }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
        }
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
    }
}

let meBubble = Color(light: .init(srgbRed: 0.04, green: 0.38, blue: 0.82, alpha: 1), dark: .init(srgbRed: 0.04, green: 0.38, blue: 0.82, alpha: 1))
let themBubble = Color(light: .init(srgbRed: 0.898, green: 0.898, blue: 0.918, alpha: 1), dark: .init(srgbRed: 0.227, green: 0.227, blue: 0.235, alpha: 1))

/// Over the first line of a voice's run: name and time.
struct TurnHeader: View {
    let line: Line
    let name: String
    var rename: (_ spk: String, _ name: String) -> Void = { _, _ in }
    @State var renaming = false

    var body: some View {
        HStack(spacing: 6) {
            if line.src != "mic" {
                if let spk = line.spk, line.src == "sys" {  // a told-apart voice: click to name it
                    Button { renaming = true } label: { Text(name).fontWeight(.semibold).foregroundStyle(themColor) }
                        .buttonStyle(.plain).help("Name this voice")
                        .popover(isPresented: $renaming) { RenameSpeaker(current: name) { rename(spk, $0) } }
                } else {
                    Text(name).fontWeight(.semibold).foregroundStyle(themColor)
                }
            }
            Text(String(clock(line.t).prefix(5))).foregroundStyle(.secondary).monospacedDigit()
        }
        .font(.system(size: 11))
        .padding(.horizontal, 12)
    }
}

/// One line as a bubble; the far side keeps a margin so bubbles never span the page. Hover shows a trash button beside it, the right-click
/// menu has Delete too. Grey (still being recognised) lines are faded and can not be deleted yet: the next pass would bring them back.
struct LineBubble: View {
    let line: Line
    let me: Bool
    let delete: (Line) -> Void
    @State var hover = false

    var body: some View {
        HStack(spacing: 6) {
            if me { Spacer(minLength: 80); trash }
            Text(line.text)
                .foregroundStyle(me ? Color.white : .primary)
                .textSelection(.enabled)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(me ? meBubble : themBubble, in: RoundedRectangle(cornerRadius: 16))
                .opacity(line.final ? 1 : 0.6)
                .help(clock(line.t))
            if !me { trash; Spacer(minLength: 80) }
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .contextMenu { Button("Delete Line...", role: .destructive) { delete(line) }.disabled(!line.final) }
    }

    var trash: some View {
        Button { delete(line) } label: { Image(systemName: "trash").font(.system(size: 11)) }
            .buttonStyle(.borderless).foregroundStyle(.red).help("Delete this line from the transcript")
            .opacity(hover && line.final ? 1 : 0).disabled(!(hover && line.final))
    }
}

/// "Who is this?" for a voice of "Them": the name replaces "Speaker N" in this meeting's transcript, summaries and answers.
struct RenameSpeaker: View {
    let current: String
    let save: (String) -> Void
    @State var name = ""
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Who is this?").font(.headline)
            TextField("Name", text: $name).frame(width: 220).onSubmit { save(name); dismiss() }
            Text("Renames every line of this voice in this meeting.").font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Save") { save(name); dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(14)
        .onAppear { name = current == "Them" || current.hasPrefix("Speaker ") ? "" : current }
    }
}

struct TypingDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20)) { ctx in  // 20 fps is plenty for three dots and far cheaper than the display's rate
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<3) { i in Circle().frame(width: 5, height: 5).opacity(0.3 + 0.7 * max(0, sin((t * 2 - Double(i) * 0.25) * .pi))) }
            }
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: chat

/// A pill at the bottom; click opens the thread with an input. x or Esc folds it back, the thread stays.
struct ChatBox: View {
    @EnvironmentObject var model: Model
    let key: String
    let label: String
    @State var open = false
    @State var q = ""
    @FocusState var focused: Bool

    var body: some View {
        Group {
            if open {
                VStack(spacing: 0) {
                    HStack {
                        Text(label).font(.headline)
                        Spacer()
                        Button { open = false } label: { Image(systemName: "xmark") }.buttonStyle(.plain).keyboardShortcut(.cancelAction).help("Close (Esc)")
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    Divider()
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(model.thread(key)) { qa in
                                Text(qa.q).padding(8).background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 8)).frame(maxWidth: .infinity, alignment: .trailing)
                                if let a = qa.a { Text(inline(a)).foregroundStyle(qa.failed ? .red : .primary).textSelection(.enabled) } else { ProgressView().controlSize(.small) }
                            }
                        }
                        .padding(14)
                    }
                    .defaultScrollAnchor(.bottom, for: .initialOffset)
                    .defaultScrollAnchor(.bottom, for: .sizeChanges)
                    .frame(height: 260)
                    Divider()
                    HStack {
                        TextField("Type a question...", text: $q).textFieldStyle(.plain).focused($focused).onSubmit(send)
                        Button("Ask", action: send).buttonStyle(.borderedProminent).disabled(q.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .padding(10)
                }
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.secondary.opacity(0.2)))
                .onAppear { focused = true }
            } else {
                Button { open = true } label: { Label(label, systemImage: "sparkles").pill() }
                    .buttonStyle(.plain)
            }
        }
        .padding(14)
        .environment(\.openURL, OpenURLAction { url in  // answers cite meetings as [Title, date](/m/<id>)
            if url.path.hasPrefix("/m/") { model.show(String(url.path.dropFirst(3))); return .handled }
            return .systemAction
        })
    }

    func send() {
        let text = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        q = ""
        model.ask(key, text)
    }
}

// MARK: settings

struct SettingsView: View {
    @AppStorage("appearance") var appearance = "system"

    var body: some View {
        Form {
            Picker("Appearance", selection: $appearance) {
                Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark")
            }
            .pickerStyle(.segmented)

            Section {
                ProviderSettings()
            } header: {
                Text("AI for summaries and answers")
            } footer: {
                Text("Waffle uses the AI tool you already have and are signed in to, with your own plan. Only transcript text is sent, and only when a summary is made or you ask something. Audio never leaves this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            TranscriptSettings()

            ScreenNamesSettings()

            AgendaSettings()

            TemplatesSettings()

            Section {
                Button("Show Setup Again...") { Model.shared.showSetup = true }
                    .help("The first-run steps: speech models, permissions and AI")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .navigationTitle("Settings")
        .onChange(of: appearance) { applyAppearance() }
    }
}

/// Settings: the pass after the call, Zoom's mute, and whether Waffle may hear the system audio.
struct TranscriptSettings: View {
    @State var polish = Model.polishEnabled
    @State var followMute = Model.followCallMute
    @State var audio = SystemAudioPermission.status

    var body: some View {
        Section {
            Toggle("Make the transcript better after the call", isOn: $polish).onChange(of: polish) { Model.polishEnabled = polish }
            Toggle("Skip what I say while muted in Zoom", isOn: $followMute).onChange(of: followMute) { Model.followCallMute = followMute }
            HStack {
                Text("System audio")
                Spacer()
                switch audio {
                case .allowed: Label("Allowed", systemImage: "checkmark.circle.fill").symbolRenderingMode(.multicolor)
                case .denied: Button("Open System Settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!) }
                case .unknown: Button("Allow...") { SystemAudioPermission.request { _ in audio = SystemAudioPermission.status } }
                }
            }
            .task { while !Task.isCancelled { audio = SystemAudioPermission.status; try? await Task.sleep(for: .seconds(2)) } }
        } header: {
            Text("Transcript")
        } footer: {
            Text("After the call, Waffle recognises the whole recording once more with full context and tells the voices apart again (no limit on how many), then writes the notes; it takes about a minute for an hour. The speech for it stays in memory only and is gone after. Muted in Zoom: what you say is not for the call, so it stays out of the notes (needs Accessibility, see Speaker names).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Which AI tool writes the summaries (Claude Code or Codex) and whether it is ready: installed and signed in. Get, Connect (signs in
/// in Terminal, then watches for it to finish) or Sign Out. Used in Settings and in the first-run setup.
struct ProviderSettings: View {
    @State var provider = Provider.current
    @State var accounts: [Provider: AIAccount] = [:]
    @State var waiting = false
    @State var poll: Timer?

    var account: AIAccount? { accounts[provider] }

    var body: some View {
        Picker("Provider", selection: $provider) {
            ForEach(Provider.allCases) { p in Text(p.name + (accounts[p]?.loggedIn == true ? "  \u{2713}" : "")).tag(p) }
        }
        .pickerStyle(.segmented)
        .onChange(of: provider) { Provider.current = provider; waiting = false; poll?.invalidate() }
        HStack(spacing: 10) {
            Image(systemName: icon.0).font(.title2).foregroundStyle(icon.1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if let a = account, !waiting {
                if !a.installed { Button("Get \(provider.name)") { NSWorkspace.shared.open(provider.site) } }
                else if !a.loggedIn { Button("Connect...", action: connect) }
                else { Button("Sign Out...", action: signOut) }
            }
            Button { refresh() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).help("Check again")
        }
        .onAppear { refresh() }
        .onDisappear { poll?.invalidate() }
    }

    var icon: (String, Color) {
        guard let a = account, !waiting else { return ("questionmark.circle", .secondary) }
        return !a.installed ? ("xmark.circle.fill", .red) : !a.loggedIn ? ("exclamationmark.triangle.fill", .orange) : ("checkmark.seal.fill", .green)
    }
    var title: String {
        guard let a = account else { return "Checking..." }
        return waiting ? "Waiting for sign-in..." : !a.installed ? "\(provider.name) is not installed" : !a.loggedIn ? "Not connected" : "Connected"
    }
    var detail: String {
        guard let a = account else { return "" }
        if waiting { return "Finish signing in in the browser page that opened." }
        if !a.installed { return "Install it, then click the arrow to check again." }
        if !a.loggedIn { return "Sign in to get summaries and answers." }
        return a.detail.flatMap { $0.isEmpty ? nil : $0 } ?? "Ready"
    }

    func refresh() {
        Task.detached {
            var all: [Provider: AIAccount] = [:]
            for p in Provider.allCases { all[p] = AI.account(p, fresh: true) }
            await MainActor.run { accounts = all }
        }
    }

    /// Sign-in is interactive (a browser page), so run the tool's login in Terminal and watch for it to finish.
    func connect() {
        let p = provider
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("waffle-connect-\(p.rawValue).command")
        try? "#!/bin/zsh -l\necho 'Signing in to \(p.name) for Waffle...'\n\(p.loginCommand) && echo && echo 'Done. You can close this window and go back to Waffle.'\n".write(to: script, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        NSWorkspace.shared.open(script)
        waiting = true
        var checks = 0
        poll?.invalidate()
        poll = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { t in
            checks += 1
            Task.detached {
                let a = AI.account(p, fresh: true)
                await MainActor.run { if a.loggedIn || checks > 60 { t.invalidate(); waiting = false; accounts[p] = a } }
            }
        }
    }

    func signOut() {
        let p = provider
        guard confirm("Sign out of \(p.name)?", "This signs \(p.name) out on this Mac, for Waffle and for the \(p.rawValue) command in Terminal. Waffle can't write summaries or answer questions with it until you connect again.", "Sign Out") else { return }
        Task.detached { AI.logout(p); let a = AI.account(p, fresh: true); await MainActor.run { accounts[p] = a } }
    }
}

/// The template library as grouped rows, like System Settings: the default at the top, then each template with a one-line gist.
/// View (built-in) or Edit (your own) opens it in a sheet; Add Template makes a new one.
struct TemplatesSettings: View {
    @ObservedObject var model = Model.shared
    @State var open: Template?   // shown in the sheet
    @State var isNew = false

    var lib: TemplateLibrary { model.library }

    var body: some View {
        Section {
            Picker("Default for meeting notes", selection: Binding(get: { lib.defaultId }, set: { model.setDefaultTemplate($0) })) {
                ForEach(lib.all) { Text($0.label).tag($0.id) }
            }
        } header: {
            Text("Summary templates")
        } footer: {
            Text("The default shapes the notes of every meeting. Regenerate on a meeting can use any other template, and each folder picks one for its updates. Waffle always adds its own rules: English, who is who, no invented facts.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Built-in") {
            ForEach(builtinTemplates) { row($0) }
        }
        Section("Your templates") {
            ForEach(lib.custom) { row($0) }
            Button { isNew = true; open = Template(id: "custom-\(UUID().uuidString.prefix(8))", name: "", text: "", emoji: templateEmojis.randomElement()) } label: {
                Label("Add Template...", systemImage: "plus")
            }
            .buttonStyle(.borderless)
        }
        .sheet(item: $open) { t in TemplateSheet(template: t, builtin: lib.isBuiltin(t.id), isNew: isNew) }
    }

    func row(_ t: Template) -> some View {
        let builtin = lib.isBuiltin(t.id)
        return HStack(spacing: 10) {
            Text(t.emoji ?? "📝").font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(t.name)
                Text(t.about ?? gist(t.text)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if t.id == lib.defaultId { DefaultStar() }
            Button("View") { isNew = false; open = t }
        }
        .contentShape(Rectangle())
        .onTapGesture { isNew = false; open = t }
        .contextMenu {
            Button("View") { isNew = false; open = t }
            if !builtin {
                Button("Delete Template...", role: .destructive) {
                    if confirm("Delete \u{201C}\(t.name)\u{201D}?", "Folders that use it go back to the default template. Summaries already written stay as they are.", "Delete") { model.deleteTemplate(t.id) }
                }
            }
        }
    }

    /// The first line of a template, without list marks, as its one-line description.
    func gist(_ text: String) -> String {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " -*#")) }.first { !$0.isEmpty } ?? ""
    }
}

/// One template in a sheet. It opens for reading, with Edit, Duplicate and, for a changed built-in one, Reset to Original; Edit turns it
/// into a form with Save and Cancel (and Delete for the user's own). A new template opens straight in the form.
struct TemplateSheet: View {
    @ObservedObject var model = Model.shared
    @Environment(\.dismiss) var dismiss
    let template: Template
    let builtin: Bool
    let isNew: Bool
    @State var editing = false
    @State var name = ""
    @State var text = ""
    @State var emoji = ""
    @State var pickingEmoji = false

    var edited: Bool { model.library.isEdited(template.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if editing {
                Text(isNew ? "New Template" : "Edit Template").font(.title3.bold())
                HStack(spacing: 10) {
                    Button { pickingEmoji = true } label: {
                        Text(emoji).font(.system(size: 20)).frame(width: 34, height: 34).background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain).help("Change the emoji")
                    .popover(isPresented: $pickingEmoji) { EmojiPicker(current: emoji, emojis: templateEmojis + folderEmojis.filter { !templateEmojis.contains($0) }) { emoji = $0 } }
                    TextField("Name", text: $name).textFieldStyle(.roundedBorder)
                }
                TextEditor(text: $text).font(.system(size: 13)).lineSpacing(3).scrollContentBackground(.hidden).frame(height: 300)
                    .padding(8).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty { Text("How the notes should look: headings, what goes under them, what to leave out.").foregroundStyle(.tertiary).padding(13).allowsHitTesting(false) }
                    }
            } else {
                HStack(spacing: 8) {
                    Text(template.label).font(.title3.bold())
                    if builtin { Badge(text: edited ? "Built-in, edited" : "Built-in", tint: .secondary) }
                    if template.id == model.library.defaultId { DefaultStar() }
                }
                ScrollView {
                    Text(template.text).font(.system(size: 13)).lineSpacing(3).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }
                .frame(height: 320)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            }
            HStack {
                if editing {
                    Spacer()
                    Button("Cancel") { if isNew { dismiss() } else { editing = false } }.keyboardShortcut(.cancelAction)
                    Button("Save") {
                        model.saveTemplate(Template(id: template.id, name: name.trimmingCharacters(in: .whitespaces), text: text, emoji: emoji))
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else {
                    if !builtin {
                        Button(role: .destructive) {
                            if confirm("Delete \u{201C}\(template.name)\u{201D}?", "Folders that use it go back to the default template. Summaries already written stay as they are.", "Delete") {
                                model.deleteTemplate(template.id); dismiss()
                            }
                        } label: { Label("Delete", systemImage: "trash") }
                        .foregroundStyle(.red)
                    }
                    Button("Duplicate") {
                        model.saveTemplate(Template(id: "custom-\(UUID().uuidString.prefix(8))", name: "\(template.name) copy", text: template.text, emoji: template.emoji))
                        dismiss()
                    }
                    .help("Make a copy under Your templates")
                    if builtin && edited {
                        Button("Reset to Original") {
                            if confirm("Reset \u{201C}\(template.name)\u{201D}?", "Your changes to this built-in template are dropped.", "Reset") { model.resetTemplate(template.id); dismiss() }
                        }
                    }
                    Spacer()
                    Button { editing = true } label: { Label("Edit", systemImage: "pencil") }
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear { name = template.name; text = template.text; emoji = template.emoji ?? "📝"; editing = isNew }
    }
}

extension View {
    /// The capsule look of the Ask and Report buttons.
    func pill() -> some View {
        padding(.horizontal, 16).padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule()).overlay(Capsule().stroke(Color.secondary.opacity(0.2)))
    }
}

/// Under a folder's meeting list. Normally a split button: "Report" writes the report for the folder's own period at once; the arrow
/// picks another period, or "Choose Meetings..." to tick them in the list. While choosing: "Select Meetings" (nothing ticked yet) or
/// "Generate (N)", and Cancel.
struct ReportBar: View {
    @EnvironmentObject var model: Model
    let folder: String

    var body: some View {
        let writing = model.writingUpdate.contains(folder)
        if model.choosing == folder {
            HStack(spacing: 8) {
                Button { model.writeUpdate(folder, Array(model.chosen)) } label: {
                    Label(model.chosen.isEmpty ? "Select Meetings" : "Generate (\(model.chosen.count))", systemImage: model.chosen.isEmpty ? "checklist" : "sparkles").pill()
                }
                .disabled(model.chosen.isEmpty)
                .foregroundStyle(model.chosen.isEmpty ? .secondary : .primary)
                .help(model.chosen.isEmpty ? "Tick the meetings for the report in the list" : "Write the report over the ticked meetings")
                Button { model.choosing = nil } label: { Text("Cancel").pill() }
            }
            .buttonStyle(.plain)
        } else {
            HStack(spacing: 0) {
                Button { model.writeReport(folder) } label: {
                    Label(writing ? "Writing Report..." : "Report", systemImage: "doc.text.magnifyingglass")
                        .padding(.leading, 16).padding(.trailing, 10).padding(.vertical, 8).contentShape(Rectangle())  // the whole part clicks, not just the text
                }
                .buttonStyle(.plain).disabled(writing)
                .help("Report over this folder's meetings for \(model.reportPeriod(folder).rawValue.lowercased()) (the folder's period)")
                Divider().frame(height: 16)
                Menu {
                    Section("Report for") {
                        ForEach(ReportPeriod.allCases, id: \.self) { p in Button(p.rawValue) { model.writeReport(folder, period: p) } }
                    }
                    Button("Choose Meetings...") { model.openReport = nil; model.choosing = folder }
                    if let last = Store.reports(folder).first {
                        Divider()
                        Button("Open Last Report") { model.selected = nil; model.openReport = OpenReport(folder: folder, id: last.id) }
                    }
                } label: {
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).padding(.leading, 8).padding(.trailing, 12).padding(.vertical, 8).contentShape(Rectangle())
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .disabled(writing)
                .help("Another period, or pick the meetings")
            }
            .background(.regularMaterial, in: Capsule()).overlay(Capsule().stroke(Color.secondary.opacity(0.2)))
        }
    }
}

/// Under Today and This Week: Report writes one over all their meetings; the template's emoji next to it picks another template for
/// this list, kept for next time.
struct ScopeReportBar: View {
    @EnvironmentObject var model: Model
    let scope: Scope

    var body: some View {
        let key = Model.scopeReports[scope]!, used = model.reportTemplate(key), writing = model.writingUpdate.contains(key)
        HStack(spacing: 0) {
            Button { model.writeScopeReport(scope) } label: {
                Label(writing ? "Writing Report..." : "Report", systemImage: "doc.text.magnifyingglass")
                    .padding(.leading, 16).padding(.trailing, 10).padding(.vertical, 8).contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(writing)
            .help("Report over the meetings of \(scope.name.lowercased()), as \u{201C}\(used.name)\u{201D}")
            Divider().frame(height: 16)
            Menu {
                Section("Template for \(scope.name) reports") {
                    ForEach(model.library.all) { t in
                        Button { model.setReportTemplate(key, t.id) } label: { if t.id == used.id { Label(t.label, systemImage: "checkmark") } else { Text(t.label) } }
                    }
                }
            } label: {
                HStack(spacing: 3) { Text(used.emoji ?? "📝"); Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary) }
                    .padding(.leading, 8).padding(.trailing, 12).padding(.vertical, 8).contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("Template: \(used.name). Click for another one")
        }
        .background(.regularMaterial, in: Capsule()).overlay(Capsule().stroke(Color.secondary.opacity(0.2)))
    }
}

/// A report in place of the folder page: the one being written, or a saved one (Copy and close are in the toolbar, see PageActions).
struct ReportView: View {
    @EnvironmentObject var model: Model
    let open: OpenReport

    var body: some View {
        let writing = open.id == nil && model.writingUpdate.contains(open.folder)
        let r = writing ? nil : open.id.map { Store.report($0) } ?? Store.reports(open.folder).first
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(model.reportName(open.folder)) report").font(.title.bold())
                Spacer()
            }
            if writing {
                Placeholder(symbol: "", title: "Writing the report", text: "The AI is reading the meetings and writing the report. This takes about a minute.", busy: true)
            } else if let r {
                Text("\(r.title)  ·  written \(shortDay(meetingDate(r.id))), \(hm(meetingDate(r.id)))").foregroundStyle(.secondary)
                Divider()
                ScrollView { MarkdownBlocks(text: r.text).padding(.vertical, 8) }
            } else {
                Placeholder(symbol: "doc", title: "This report is gone", text: "It was deleted. Past reports are on the folder page.")
            }
        }
        .padding(.horizontal, 24).padding(.top, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Marks the default template: a star instead of the word.
struct DefaultStar: View {
    var body: some View { Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow).help("Default template") }
}

struct Badge: View {
    let text: String
    let tint: Color
    var body: some View {
        Text(text).font(.caption2.weight(.semibold)).foregroundStyle(tint)
            .padding(.horizontal, 6).padding(.vertical, 2).background(tint.opacity(0.15), in: Capsule())
    }
}

/// "system", "light" or "dark" from Settings.
func applyAppearance() {
    NSApp.appearance = switch UserDefaults.standard.string(forKey: "appearance") {
        case "light": NSAppearance(named: .aqua)
        case "dark": NSAppearance(named: .darkAqua)
        default: nil
    }
}
