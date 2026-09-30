// Waffle: private meeting notes for macOS. Live on-device transcript, summaries and Q&A through the user's own Claude Code or Codex.
import SwiftUI

@main
struct WaffleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject var model = Model.shared

    var body: some Scene {
        Window("Waffle", id: "main") {
            MainView().environmentObject(model)
        }
        .defaultSize(width: 1240, height: 800)
        .commands {
            SidebarCommands()  // Toggle Sidebar, Control-Command-S
            CommandGroup(after: .sidebar) {
                Button("All Meetings") { model.scope = .all; model.selected = nil }.keyboardShortcut("1")
                Button("Back") { model.back() }.keyboardShortcut("[").disabled(model.history.isEmpty)
            }
            CommandGroup(replacing: .appSettings) {  // Settings is a page of the main window, not a window of its own
                Button("Settings...") { model.showSettings() }.keyboardShortcut(",")
            }
            CommandGroup(replacing: .newItem) {
                Button("New Meeting") { model.startNew() }.keyboardShortcut("n").disabled(model.busy)
            }
        }

        MenuBarExtra {
            MenuBarMenu().environmentObject(model)
        } label: {
            Image(nsImage: menuBarIcon(recording: model.status == .recording))
        }
    }
}

/// Waveform, or a red record icon while recording.
func menuBarIcon(recording: Bool) -> NSImage {
    let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
    let img = NSImage(systemSymbolName: recording ? "record.circle.fill" : "waveform", accessibilityDescription: "Waffle")!
        .withSymbolConfiguration(recording ? cfg.applying(.init(paletteColors: [.systemRed])) : cfg)!
    img.isTemplate = !recording
    return img
}

struct MenuBarMenu: View {
    @EnvironmentObject var model: Model
    @Environment(\.openWindow) var openWindow

    var body: some View {
        switch model.status {
        case .recording: Text("Recording" + (model.activeId.flatMap { Store.title($0) }.map { ": \($0)" } ?? ""))
        case .finalizing, .summarizing: Text("Writing the summary...")
        default: Text("Not recording")
        }
        Divider()
        if model.status == .recording {
            Button("End Meeting") { model.endMeeting() }
        } else if !model.busy {
            Button("New Meeting") { model.startNew() }
        }
        Button(model.busy ? "Show Meeting" : "Open Waffle") {
            model.openMain = { openWindow(id: "main") }
            model.show(model.busy ? model.activeId : nil)
        }
        Button("Settings...") {
            model.openMain = { openWindow(id: "main") }
            model.showSettings()
        }
        Divider()
        Button("Quit Waffle") { NSApp.terminate(nil) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        applyAppearance()
        Panels.shared.start()
        if CommandLine.arguments.contains("--record") { Model.shared.startNew() }  // ponytail: for testing from a terminal, which already has the permissions
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard Model.shared.busy else { return .terminateNow }
        let a = NSAlert()
        a.messageText = "A meeting is still being recorded"
        a.informativeText = "Quitting stops the recording. You can continue it or make the summary later from the meeting page."
        a.addButton(withTitle: "Keep Recording")
        a.addButton(withTitle: "Quit")
        return a.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ n: Notification) { Model.shared.quit() }

    // Closing the window keeps the app (and the recording) running; the Dock icon or the menu bar brings it back.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { Model.shared.openMain?() }
        return true
    }
}
