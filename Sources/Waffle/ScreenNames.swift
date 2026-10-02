// Names from the call app's window (Zoom, Microsoft Teams) while a meeting records: who is in the call, and who is talking when the
// app shows it. Read from the window's accessibility labels when Waffle is allowed (Privacy & Security > Accessibility), else from the
// text in the window (Vision text recognition on a screenshot of that one window, which Screen & System Audio Recording covers).
// Only the names are kept; screenshots never leave memory. Logic.swift turns the names into speaker labels.
import ApplicationServices
import ScreenCaptureKit
import SwiftUI
import Vision

/// What the call window showed at one moment. t: epoch ms.
struct ScreenLook { var t: Int; var people: [String]; var talking: [String] }

final class ScreenNames {
    /// The call apps this reads, by bundle id.
    static let apps: Set<String> = ["us.zoom.xos", "com.microsoft.teams2", "com.microsoft.teams"]
    /// Settings: on unless turned off.
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "screenNames") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "screenNames") }
    }

    var onLook: (ScreenLook) -> Void = { _ in }  // on the main queue
    private var task: Task<Void, Never>?
    private var lastRead = 0.0  // the last screenshot read, they cost more than the labels
    private var opened: Set<pid_t> = []  // apps asked to show their web content to accessibility

    func start() {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)  // a busy call app must not hold us up
        task = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                guard let me = self else { return }
                if let look = await me.look() { DispatchQueue.main.async { me.onLook(look) } }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    /// A look still being read when this is called is dropped, so it can not land in the next recording.
    func stop() { task?.cancel(); task = nil; onLook = { _ in } }

    private func look() async -> ScreenLook? {
        let pids = NSWorkspace.shared.runningApplications.filter { Self.apps.contains($0.bundleIdentifier ?? "") }.map(\.processIdentifier)
        guard !pids.isEmpty else { return nil }
        var texts: [String] = []
        if AXIsProcessTrusted() { for pid in pids { texts += labels(pid) } }
        // No one shown as talking in the labels (or no access to them): read the window's text, every 9 s at most.
        let now = Date().timeIntervalSince1970
        if speakingNames(texts).isEmpty && now - lastRead >= 9 {
            lastRead = now
            for pid in pids { texts += await windowText(pid) }
        }
        let look = ScreenLook(t: Int(now * 1000), people: rosterNames(texts), talking: speakingNames(texts))
        return look.people.isEmpty && look.talking.isEmpty ? nil : look
    }

    /// Titles, descriptions and values in the app's windows, at most 3000 elements and one second.
    private func labels(_ pid: pid_t) -> [String] {
        let app = AXUIElementCreateApplication(pid)
        if !opened.contains(pid) {  // Chromium-based apps build their web content's accessibility only when asked
            opened.insert(pid)
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        var windows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success, let top = windows as? [AXUIElement] else { return [] }
        let keys = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXHelpAttribute, kAXChildrenAttribute] as CFArray
        var out: [String] = [], stack = top.map { ($0, 0) }, visited = 0
        let until = Date().addingTimeInterval(1)
        while let next = stack.popLast(), visited < 3000, Date() < until {
            visited += 1
            let (e, depth) = next
            var values: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(e, keys, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
                  let v = values as? [AnyObject], v.count == 5 else { continue }
            for s in v.prefix(4).compactMap({ $0 as? String }) where !s.isEmpty && s.count <= 120 { out.append(s) }
            if depth < 50, let kids = v[4] as? [AXUIElement] { stack += kids.map { ($0, depth + 1) } }
        }
        return out
    }

    /// Text recognised in a screenshot of the app's biggest window on screen.
    private func windowText(_ pid: pid_t) async -> [String] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true),
              let w = content.windows.filter({ $0.owningApplication?.processID == pid && $0.frame.width >= 300 && $0.frame.height >= 200 })
                .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
        else { return [] }
        let cfg = SCStreamConfiguration()
        let scale = min(2, 1800 / w.frame.width)  // big enough for name labels, small enough to read fast
        cfg.width = Int(w.frame.width * scale); cfg.height = Int(w.frame.height * scale)
        cfg.showsCursor = false
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: w), configuration: cfg) else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false  // names are not dictionary words
        request.automaticallyDetectsLanguage = true
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }
}

/// Settings: names from Zoom and Teams on or off, and whether Waffle may read the apps' accessibility labels (more reliable than the
/// text on screen).
struct ScreenNamesSettings: View {
    @State var on = ScreenNames.enabled
    @State var trusted = AXIsProcessTrusted()

    var body: some View {
        Section {
            Toggle("Name speakers from Zoom and Teams", isOn: $on)
                .onChange(of: on) { ScreenNames.enabled = on }
            if on {
                HStack(spacing: 10) {
                    Image(systemName: trusted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill").font(.title2).foregroundStyle(trusted ? Color.green : .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(trusted ? "Accessibility allowed" : "Accessibility not allowed").fontWeight(.semibold)
                        Text(trusted ? "Waffle reads who is talking from the call app's labels." : "Waffle reads the names in the call window instead, which is less reliable.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !trusted {
                        Button("Allow...") { _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) }
                            .help("Opens System Settings > Privacy & Security > Accessibility")
                    }
                }
                .task {  // it can be allowed in System Settings while this is open
                    while !Task.isCancelled {
                        trusted = AXIsProcessTrusted()
                        try? await Task.sleep(for: .seconds(2))
                    }
                }
            }
        } header: {
            Text("Speaker names")
        } footer: {
            Text("While a call records, Waffle looks at the Zoom or Teams window for who is in the call and who is talking, and gives those names to the voices it tells apart. Only the names are kept; nothing from the screen is stored or sent.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
