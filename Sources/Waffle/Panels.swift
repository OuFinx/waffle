// The always-on parts around a recording: the edge tab, the floating transcript popup and the "record this call?" prompt.
import AppKit
import Combine
import SwiftUI

/// A borderless panel still has to take the keyboard, for typing notes in the popup and for "click elsewhere closes it".
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Moves its window when dragged. Controls must sit outside it.
final class DragStrip: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with e: NSEvent) { window?.performDrag(with: e) }
}

struct DragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragStrip() }
    func updateNSView(_ v: NSView, context: Context) {}
}

// MARK: edge tab

/// The body of the edge tab: a dark capsule of five softly moving red level bars (no icon), and all the mouse handling.
/// Click opens the transcript; press and drag moves the tab, and on release it snaps to the nearest side of the screen.
final class TabView: NSView {
    var onClick: () -> Void = {}
    var onMoved: () -> Void = {}
    var edge = "right" { didSet { needsDisplay = true } }  // "left", "right", "top", "bottom" when docked, "free" when floating
    private var bars: [CALayer] = []
    private var pressAt = NSPoint.zero, startOrigin = NSPoint.zero, dragging = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = frame.width / 2
        layer?.borderWidth = 0.5
        for i in 0..<5 {  // horizontal bars stacked down the middle, each breathing from its centre
            let bar = CALayer()
            bar.frame = CGRect(x: (frame.width - 18) / 2, y: frame.height / 2 - 14 + CGFloat(i) * 6, width: 18, height: 3)
            bar.cornerRadius = 1.5
            layer?.addSublayer(bar)
            bars.append(bar)
        }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .activeAlways, .inVisibleRect], owner: self))
        toolTip = "Waffle is recording. Click to see the live transcript, drag to move."
    }
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = NSColor(srgbRed: 0.08, green: 0.08, blue: 0.086, alpha: 0.88).cgColor  // dark in both themes, like a HUD
        layer?.borderColor = NSColor.white.withAlphaComponent(0.1).cgColor
        // Docked: flat against the screen edge, rounded on the other side. Floating: rounded all round.
        layer?.maskedCorners = switch edge {
            case "right": [.layerMinXMinYCorner, .layerMinXMaxYCorner]
            case "left": [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
            case "top": [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            case "bottom": [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            default: [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        }
    }

    /// Bars bounce while recording, rest grey while the notes are written.
    func setRecording(_ on: Bool) {
        let colour = on ? NSColor(srgbRed: 1, green: 0.38, blue: 0.33, alpha: 1) : NSColor.white.withAlphaComponent(0.35)  // the capsule is always dark
        for (i, bar) in bars.enumerated() {
            bar.backgroundColor = colour.cgColor
            if on && bar.animation(forKey: "level") == nil {
                let a = CABasicAnimation(keyPath: "transform.scale.x")
                a.fromValue = 0.33; a.toValue = 1
                a.duration = [0.45, 0.62, 0.52, 0.58, 0.48][i]
                a.autoreverses = true; a.repeatCount = .infinity
                a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                a.beginTime = CACurrentMediaTime() + [0, 0.18, 0.09, 0.27, 0.13][i]
                bar.add(a, forKey: "level")
            } else if !on {
                bar.removeAnimation(forKey: "level")
            }
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func cursorUpdate(with event: NSEvent) { NSCursor.openHand.set() }

    override func mouseDown(with e: NSEvent) {
        pressAt = NSEvent.mouseLocation
        startOrigin = window!.frame.origin
        dragging = false
    }

    override func mouseDragged(with e: NSEvent) {
        let p = NSEvent.mouseLocation
        if !dragging && hypot(p.x - pressAt.x, p.y - pressAt.y) < 4 { return }  // a little wobble is still a click
        if !dragging { dragging = true; NSCursor.closedHand.set() }
        window!.setFrameOrigin(NSPoint(x: startOrigin.x + p.x - pressAt.x, y: startOrigin.y + p.y - pressAt.y))
    }

    override func mouseUp(with e: NSEvent) {
        if dragging { NSCursor.openHand.set(); onMoved() } else { onClick() }
        dragging = false
    }
}

/// While a meeting records: a small tab docked to a side of the screen (the middle of the right side until you move it),
/// above all windows and on every desktop.
final class RecordingTab: NSPanel {
    let body = TabView(frame: NSRect(x: 0, y: 0, width: 34, height: 80))
    static let stickDistance: CGFloat = 50  // released closer than this to a screen edge, the tab docks to it

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 34, height: 80), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        contentView = body
        body.onMoved = { [unowned self] in self.snap() }
        body.setRecording(true)
    }

    var screenFrame: NSRect { (screen ?? NSScreen.main ?? NSScreen.screens.first)!.visibleFrame }

    /// Put the tab where it was left. Docked tabs remember the edge and their place along it, floating ones their spot,
    /// both as shares of the screen so they survive a resolution change.
    func dock() {
        let d = UserDefaults.standard, s = screenFrame
        let edge = d.string(forKey: "tabEdge") ?? "right"
        let fx = d.object(forKey: "tabX") as? Double ?? 1, fy = d.object(forKey: "tabY") as? Double ?? 0.5
        var o = NSPoint(x: s.minX + s.width * fx - frame.width / 2, y: s.minY + s.height * fy - frame.height / 2)
        switch edge {
            case "right": o.x = s.maxX - frame.width + 1
            case "left": o.x = s.minX - 1
            case "top": o.y = s.maxY - frame.height + 1
            case "bottom": o.y = s.minY - 1
            default: break
        }
        body.edge = edge
        setFrameOrigin(clamped(o, edge))
    }

    /// Keep the tab on screen; a docked tab may overhang its own edge by a point so it looks attached.
    func clamped(_ o: NSPoint, _ edge: String) -> NSPoint {
        let s = screenFrame
        let x = ["left", "right"].contains(edge) ? o.x : min(max(o.x, s.minX), s.maxX - frame.width)
        let y = ["top", "bottom"].contains(edge) ? o.y : min(max(o.y, s.minY), s.maxY - frame.height)
        return NSPoint(x: x, y: y)
    }

    /// After a drag: dock to a screen edge if released near it, otherwise stay exactly where dropped. The shape follows.
    func snap() {
        let s = screenFrame, f = frame
        let distances = ["left": f.minX - s.minX, "right": s.maxX - f.maxX, "top": s.maxY - f.maxY, "bottom": f.minY - s.minY]
        let nearest = distances.min { $0.value < $1.value }!
        let edge = nearest.value < Self.stickDistance ? nearest.key : "free"
        var o = f.origin
        switch edge {
            case "right": o.x = s.maxX - f.width + 1
            case "left": o.x = s.minX - 1
            case "top": o.y = s.maxY - f.height + 1
            case "bottom": o.y = s.minY - 1
            default: break
        }
        o = clamped(o, edge)
        let d = UserDefaults.standard
        d.set(edge, forKey: "tabEdge")
        d.set(Double((o.x + f.width / 2 - s.minX) / s.width), forKey: "tabX")
        d.set(Double((o.y + f.height / 2 - s.minY) / s.height), forKey: "tabY")
        body.edge = edge
        setFrame(NSRect(origin: o, size: frame.size), display: true, animate: true)  // glide onto the edge (animator() does not move panels)
    }
}

// MARK: controller

final class Panels: NSObject {
    static let shared = Panels()
    let model = Model.shared
    weak var mainWindow: NSWindow?
    private var tab: RecordingTab!
    private var mini: FloatingPanel!
    private var prompt: NSPanel?
    private var promptApps: Set<String> = []
    private var dismissedApps: Set<String> = []  // "not now" for these call apps until they release the mic
    private var miniFor: String?  // meeting shown in the popup
    private var subs: Set<AnyCancellable> = []

    func start() {
        tab = RecordingTab()
        tab.body.onClick = { [unowned self] in showMini() }

        // The transcript popup: a rounded borderless panel; its SwiftUI header has the mic switch, pin, open and End Meeting.
        mini = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 460), styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        mini.isFloatingPanel = true
        mini.level = .floating
        mini.hidesOnDeactivate = false
        mini.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        mini.isReleasedWhenClosed = false
        mini.backgroundColor = .clear
        mini.isOpaque = false
        mini.hasShadow = true
        mini.minSize = NSSize(width: 280, height: 240)
        mini.contentView = NSHostingView(rootView: MiniView().environmentObject(model))
        if !mini.setFrameUsingName("popup"), let s = NSScreen.main?.visibleFrame { mini.setFrameOrigin(NSPoint(x: s.maxX - 380, y: s.maxY - 480)) }
        mini.setFrameAutosaveName("popup")
        // Unpinned, the popup behaves like a popover: clicking anywhere else closes it.
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: mini, queue: .main) { [unowned self] _ in
            if !model.pinned { mini.orderOut(nil); update() }
        }
        // The tab shows only when Waffle is out of sight: react right away when you switch apps or minimise or close the window.
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification, NSApplication.didHideNotification,
                     NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [unowned self] _ in DispatchQueue.main.async { self.update() } }
        }
        model.$status.combineLatest(model.$activeId, model.$pinned).sink { [unowned self] _ in DispatchQueue.main.async { self.update() } }.store(in: &subs)
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [unowned self] _ in updatePrompt(model.watch()) }
    }

    /// While a meeting records: the popup when it is pinned, and the edge tab whenever neither the popup nor the main window is in view.
    /// Both go away the moment it stops.
    func update() {
        guard let id = model.activeId, model.status == .recording else {  // End Meeting: gone at once, the notes are written in the background
            tab.orderOut(nil); mini.orderOut(nil); miniFor = nil
            return
        }
        if miniFor != id { miniFor = id; if model.pinned { showMini() } }  // pinned: opens by itself when a recording starts
        let mainInFront = NSApp.isActive && !NSApp.isHidden && mainWindow?.isVisible == true && mainWindow?.isMiniaturized == false
        if !mini.isVisible && !mainInFront {
            if !tab.isVisible { tab.dock(); tab.orderFrontRegardless() }
        } else {
            tab.orderOut(nil)
        }
    }

    /// Opens beside the edge tab, on the tab's side of the screen, unless it is pinned: then it stays where you put it.
    func showMini() {
        if !model.pinned {
            if !tab.isVisible { tab.dock() }
            let s = tab.screenFrame, t = tab.frame, size = mini.frame.size
            let o: NSPoint = switch tab.body.edge {
                case "top": NSPoint(x: t.midX - size.width / 2, y: t.minY - size.height - 8)
                case "bottom": NSPoint(x: t.midX - size.width / 2, y: t.maxY + 8)
                case "left": NSPoint(x: t.maxX + 8, y: t.midY - size.height / 2)
                case "right": NSPoint(x: t.minX - size.width - 8, y: t.midY - size.height / 2)
                default: NSPoint(x: t.minX - size.width - 8 >= s.minX ? t.minX - size.width - 8 : t.maxX + 8, y: t.midY - size.height / 2)
            }
            mini.setFrameOrigin(NSPoint(x: min(max(o.x, s.minX), s.maxX - size.width), y: min(max(o.y, s.minY), s.maxY - size.height)))
        }
        tab.orderOut(nil)
        mini.makeKeyAndOrderFront(nil)
    }

    // MARK: "record this call?" prompt

    func updatePrompt(_ list: [String]) {
        let apps = Set(list)
        if apps.isEmpty { dismissedApps = [] }
        guard !model.busy, !apps.isEmpty, !apps.isSubset(of: dismissedApps) else { closePrompt(); return }
        if prompt == nil { showPrompt(apps.sorted()) }
    }

    /// A small card at the top right, like a notification: app icon, which app took the microphone, Record / Continue / x.
    private func showPrompt(_ apps: [String]) {
        let p = FloatingPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .floating
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        let resume = model.resumable()
        let card = NSHostingView(rootView: CallPrompt(apps: apps, resume: resume?.title,
                                                      record: { [unowned self] in promptRecord() },
                                                      resumeAction: { [unowned self] in promptResume() },
                                                      dismiss: { [unowned self] in promptDismiss() }))
        p.contentView = card
        p.setContentSize(card.fittingSize)
        if let s = NSScreen.main?.visibleFrame { p.setFrameOrigin(NSPoint(x: s.maxX - p.frame.width - 12, y: s.maxY - p.frame.height - 12)) }
        p.orderFrontRegardless()
        prompt = p
        dismissedApps = []
        promptApps = Set(apps)
    }

    private func closePrompt() { prompt?.orderOut(nil); prompt = nil }

    private func promptRecord() { closePrompt(); model.startNew() }
    private func promptResume() { closePrompt(); if let r = model.resumable() { model.resume(r.id) } }
    private func promptDismiss() { dismissedApps = promptApps; closePrompt() }
}

// MARK: popup content

/// The popup, like Messages: a header bar (recording dot and time, mic, pin, open, End), the live transcript as bubbles (Them left in grey,
/// Me right in blue, the same as the meeting page), and a note field at the bottom like a message composer.
struct MiniView: View {
    @EnvironmentObject var model: Model
    @Environment(\.colorScheme) var scheme
    @State var notes = ""
    @State var savedNotes = ""
    @State var pulse = false

    var id: String? { model.activeId }
    var recording: Bool { model.status == .recording }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            bubbles
            TextField("Add a note...", text: $notes, axis: .vertical)
                .textFieldStyle(.plain).lineLimit(1...5)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.08)))
                .help("Your notes for this meeting. The summary is built around them.")
                .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 12)
        }
        .background(popupColor)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .onAppear(perform: loadNotes)
        .onChange(of: id) { loadNotes() }
        .task(id: notes) {
            guard let id, notes != savedNotes else { return }
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            Store.saveNotes(id, notes); savedNotes = notes
        }
    }

    func loadNotes() {
        guard let id else { return }
        notes = Store.notes(id); savedNotes = notes
    }

    var header: some View {
        HStack(spacing: 8) {
            Circle().fill(recording ? .red : .secondary).frame(width: 8, height: 8)
                .opacity(recording && pulse ? 0.35 : 1)
                .animation(recording ? .easeInOut(duration: 0.9).repeatForever() : .default, value: pulse)
                .onAppear { pulse = true }
            VStack(alignment: .leading, spacing: 0) {
                Text(recording ? "Recording" : model.busy ? "Writing notes..." : "Done").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if recording, let id {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in Text(elapsed(Int(Date().timeIntervalSince(meetingDate(id))))).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary) }
                }
            }
            .fixedSize()
            DragArea().frame(maxWidth: .infinity, maxHeight: .infinity)  // drag the popup by the header, between the text and the buttons
            HStack(spacing: 6) {
                if recording {
                    Button { model.micMuted.toggle() } label: { Image(systemName: model.micMuted ? "mic.slash.fill" : "mic.fill") }
                        .buttonStyle(RoundIcon(tint: model.micMuted ? .red : .primary, on: model.micMuted))
                        .help(model.micMuted ? "Your microphone is not transcribed. Click to transcribe \u{201C}Me\u{201D} again." : "Stop transcribing your microphone (\u{201C}Me\u{201D}). The call still hears you.")
                }
                Button { model.pinned.toggle() } label: { Image(systemName: model.pinned ? "pin.fill" : "pin") }
                    .buttonStyle(RoundIcon(tint: model.pinned ? .accentColor : .primary, on: model.pinned))
                    .help(model.pinned ? "Unpin: close when you click elsewhere" : "Pin: keep this open during meetings")
                Button { model.show(id) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(RoundIcon())
                    .help("Open in Waffle")
                if recording {
                    Button { model.endMeeting() } label: {
                        Text("End").font(.system(size: 13, weight: .semibold)).foregroundStyle(softRed)
                            .padding(.horizontal, 12).frame(height: 28).background(Color.red.opacity(0.16), in: Capsule()).contentShape(Capsule())
                    }
                    .buttonStyle(.plain).fixedSize()  // the drag area must not squeeze it
                    .help("End meeting: stop recording and write the notes")
                }
            }
        }
        .padding(.leading, 14).padding(.trailing, 10)
        .frame(height: 48)
        .background(cardColor)
    }

    /// A speaker label only where the speaker changes; typing dots at the end for whoever is talking right now.
    var bubbles: some View {
        let typing = recording ? ["sys", "mic"].filter(model.hearing.contains) : []
        let names = id.map { speakerNames(model.lines, names: Store.speakers($0)) } ?? [:]
        let items: [(String, String, Bool, Line?)] = model.lines.map { (label($0, names), $0.text, $0.final, $0) } + typing.map { ($0 == "mic" ? "Me" : "Them", "", true, nil) }
        return ScrollView {
            LazyVStack(spacing: 4) {
                if items.isEmpty { Text("Listening. Text appears here a few seconds after people speak.").foregroundStyle(.secondary).padding(.top, 20) }
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    let (who, text, final, line) = item
                    let me = who == "Me"
                    if !me && (i == 0 || items[i - 1].0 != who) {  // names only for the other voices, like a group chat
                        Text(who).font(.caption.weight(.semibold)).foregroundStyle(themColor)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 10).padding(.top, 6)
                    }
                    Bubble(text: text, final: final, me: me) { if let line, let id { model.confirmDeleteLine(id, line) } }
                }
            }
            .padding(12)
        }
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
    }
}

/// The popup's header buttons: all the same round 28 pt button. `on` tints the background for a switch that is on; `fill` is a solid colour.
struct RoundIcon: ButtonStyle {
    var tint: Color = .primary
    var on = false
    var fill: Color?
    @State private var hover = false

    func makeBody(configuration: Configuration) -> some View {
        let base: Color = fill ?? (on ? tint.opacity(0.3) : Color.primary.opacity(hover ? 0.12 : 0.06))
        return configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 28, height: 28)
            .background(Circle().fill(base).opacity(configuration.isPressed ? 0.7 : 1))
            .contentShape(Circle())
            .onHover { hover = $0 }
    }
}

/// The "record this call?" card.
struct CallPrompt: View {
    let apps: [String]
    let resume: String?
    let record: () -> Void
    let resumeAction: () -> Void
    let dismiss: () -> Void
    @Environment(\.colorScheme) var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Record this meeting?").font(.headline)
                    Text("\(apps.joined(separator: ", ")) is using the microphone.").font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).padding(5).contentShape(Circle()) }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("Not now: ask again when a new call starts")
            }
            HStack(spacing: 8) {
                Button(action: record) {
                    Label("Record", systemImage: "record.circle.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(.red).controlSize(.large)
                if let resume {
                    Button(action: resumeAction) { Text("Continue \u{201C}\(resume.prefix(18))\u{201D}").lineLimit(1).frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered).controlSize(.large).help("This meeting was cut off when Waffle quit. Keep recording into it.")
                } else {
                    Button("Not Now", action: dismiss).buttonStyle(.bordered).controlSize(.large)
                }
            }
        }
        .padding(16)
        .frame(width: 340)
        .background { if scheme == .light { paper } else { VisualEffect() } }
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.primary.opacity(0.08)))
    }
}

/// One chat bubble (Them left, Me right). A final line shows a trash button beside it on hover, and in the right-click menu.
struct Bubble: View {
    let text: String
    let final: Bool
    let me: Bool
    let delete: () -> Void
    @State var hover = false

    var body: some View {
        let trash = Button(action: delete) { Image(systemName: "trash").font(.caption) }
            .buttonStyle(.borderless).foregroundStyle(.red).help("Delete this line from the transcript")
            .opacity(hover && final && !text.isEmpty ? 1 : 0).disabled(!final || text.isEmpty)
        HStack(spacing: 6) {
            if me { Spacer(minLength: 40); trash }
            Group { if text.isEmpty { TypingDots() } else { Text(text).textSelection(.enabled) } }
                .foregroundStyle(me ? Color.white : .primary)
                .padding(.horizontal, 11).padding(.vertical, 6)
                .background(me ? meBubble : themBubble, in: RoundedRectangle(cornerRadius: 15))
                .opacity(final ? 1 : 0.6)
            if !me { trash; Spacer(minLength: 40) }
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .contextMenu { if final && !text.isEmpty { Button("Delete Line...", role: .destructive, action: delete) } }
    }
}

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}
