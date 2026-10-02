// The first-run setup, as a sheet over the main window: welcome, the speech models download, microphone and system audio
// permissions, the AI provider, done. Each step is one page with a big icon; Settings has everything again later.
import AVFoundation
import FluidAudio
import SwiftUI

enum SetupStep: Int, CaseIterable { case welcome, models, microphone, systemAudio, ai, done }

struct SetupView: View {
    @EnvironmentObject var model: Model
    @StateObject var download = ModelDownload()
    @State var step = SetupStep.welcome
    @State var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State var screenAllowed = CGPreflightScreenCaptureAccess()

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case .welcome: welcome
                case .models: models
                case .microphone: microphone
                case .systemAudio: systemAudio
                case .ai: ai
                case .done: done
                }
            }
            .id(step)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .move(edge: .leading).combined(with: .opacity)))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 44).padding(.top, 36)
            footer
        }
        .frame(width: 560, height: 520)
        .background(popupColor)
        .task {  // permissions can change in System Settings while this is open
            while !Task.isCancelled {
                micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
                screenAllowed = CGPreflightScreenCaptureAccess()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    // MARK: pages

    var welcome: some View {
        SetupPage(title: "Welcome to Waffle", text: "Meeting notes that write themselves, privately on your Mac.") {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 104, height: 104)
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                Feature(symbol: "waveform", tint: .red, title: "Live transcript", text: "Everyone in the call, as they speak, recognised on this Mac.")
                Feature(symbol: "sparkles", tint: .purple, title: "Notes by your AI", text: "Claude Code or Codex turns the transcript into a summary.")
                Feature(symbol: "lock.fill", tint: .green, title: "Private", text: "Audio is never stored and never leaves this Mac.")
            }
        }
    }

    var models: some View {
        SetupPage(title: "Download the speech models", text: "Waffle recognises speech on your Mac, so it needs its models once: about 700 MB. They stay on this Mac.") {
            HeroIcon(symbol: "arrow.down.circle.fill", colors: [.blue, .cyan])
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                ProgressRow(title: "Speech recognition", detail: download.speechDetail, value: download.speechDone ? 1 : download.progress, done: download.speechDone)
                ProgressRow(title: "Who is speaking", detail: download.speakersDone ? "Ready" : download.speechDone ? "Downloading..." : "Next", value: download.speakersDone ? 1 : nil, done: download.speakersDone)
                if let e = download.error {
                    HStack { Label(e, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor).font(.callout); Spacer(); Button("Try Again") { download.start() } }
                } else if !download.allDone {
                    Text("You can keep this open and wait, it takes a few minutes on a usual connection.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .onAppear { download.start() }
        }
    }

    var microphone: some View {
        SetupPage(title: "Allow the microphone", text: "So Waffle hears your side of the call. You can pause it any time with the mic button while recording.") {
            HeroIcon(symbol: "mic.fill", colors: [.orange, .red])
        } content: {
            PermissionRow(granted: micStatus == .authorized, denied: micStatus == .denied || micStatus == .restricted, allow: "Allow Microphone",
                          settings: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                Task { _ = await AVCaptureDevice.requestAccess(for: .audio); micStatus = AVCaptureDevice.authorizationStatus(for: .audio) }
            }
        }
    }

    var systemAudio: some View {
        SetupPage(title: "Allow system audio", text: "So Waffle hears the other people in the call. macOS calls this Screen & System Audio Recording: Waffle records only the sound, and reads just the names in a Zoom or Teams window.") {
            HeroIcon(symbol: "speaker.wave.2.fill", colors: [.teal, .blue])
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                PermissionRow(granted: screenAllowed, denied: false, allow: "Allow System Audio",
                              settings: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    _ = CGRequestScreenCaptureAccess()
                }
                if !screenAllowed {
                    Text("After you switch Waffle on in System Settings, macOS may ask to quit and reopen it. Your setup continues where you left off.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    var ai: some View {
        SetupPage(title: "Pick your AI", text: "Summaries and answers come from the AI tool you already use, with your own plan. Only transcript text is sent, never audio.") {
            HeroIcon(symbol: "sparkles", colors: [.purple, .pink])
        } content: {
            Form { ProviderSettings() }.formStyle(.grouped).scrollContentBackground(.hidden).scrollDisabled(true).frame(height: 130).padding(.horizontal, -20)
        }
    }

    var done: some View {
        SetupPage(title: "You're all set", text: "Join a call in Zoom, Teams, Meet or Slack and Waffle offers to record it. Or click New any time.") {
            HeroIcon(symbol: "checkmark", colors: [.green, .mint])
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                Feature(symbol: "rectangle.portrait.righthalf.inset.filled", tint: .red, title: "The edge tab", text: "While recording, a small tab sits at the screen edge. Click it for the live transcript.")
                Feature(symbol: "folder.fill", tint: .blue, title: "Folders and reports", text: "Drag meetings into folders and get a weekly report for each.")
            }
        }
    }

    // MARK: footer

    var footer: some View {
        HStack {
            if step != .welcome && step != .done { Button("Back") { go(-1) }.keyboardShortcut(.cancelAction) }
            Spacer()
            HStack(spacing: 7) {
                ForEach(SetupStep.allCases, id: \.self) { s in Circle().fill(s == step ? Color.primary.opacity(0.7) : Color.primary.opacity(0.18)).frame(width: 7, height: 7) }
            }
            Spacer()
            if step == .done {
                Button("Start Using Waffle") { finish() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            } else {
                Button(step == .models && !download.allDone ? "Downloading..." : "Continue") { go(1) }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(step == .models && !download.allDone)
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 24).padding(.vertical, 18)
        .overlay(alignment: .top) { Divider() }
    }

    func go(_ by: Int) {
        withAnimation(.snappy) { step = SetupStep(rawValue: step.rawValue + by) ?? step }
    }

    func finish() {
        UserDefaults.standard.set(true, forKey: "setupDone")
        model.showSetup = false
    }
}

// MARK: pieces

/// One setup page: hero icon, title, a line of text, then the page's own content.
struct SetupPage<Hero: View, Content: View>: View {
    let title: String
    let text: String
    @ViewBuilder let hero: Hero
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            hero.padding(.bottom, 18)
            Text(title).font(.system(size: 24, weight: .bold)).multilineTextAlignment(.center)
            Text(text).font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.top, 6)
            content.padding(.top, 24).frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
        }
    }
}

/// A big rounded square with a gradient and a white symbol, like the icons in System Settings, only larger.
struct HeroIcon: View {
    let symbol: String
    let colors: [Color]
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 42, weight: .semibold)).foregroundStyle(.white)
            .frame(width: 88, height: 88)
            .background(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: colors.last!.opacity(0.35), radius: 12, y: 6)
    }
}

/// A small tinted symbol with a title and a line of text.
struct Feature: View {
    let symbol: String
    let tint: Color
    let title: String
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 32, height: 32).background(tint.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }
}

/// A download line: name, what is happening, and a bar (none while waiting for its turn), or a green tick when done.
struct ProgressRow: View {
    let title: String
    let detail: String
    let value: Double?
    let done: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer()
                if done { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) } else { Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit() }
            }
            if let value { ProgressView(value: value).tint(done ? .green : .accentColor) } else { ProgressView().progressViewStyle(.linear).opacity(0.5) }
        }
        .padding(12)
        .background(cardColor, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Allowed (a green tick), or a button that asks, and a link to System Settings once macOS has been told no.
struct PermissionRow: View {
    let granted: Bool
    let denied: Bool
    let allow: String
    let settings: String
    let request: () -> Void
    var body: some View {
        HStack {
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill").symbolRenderingMode(.multicolor).font(.system(size: 13, weight: .semibold))
            } else if denied {
                Label("Turned off in System Settings", systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor).font(.system(size: 13))
            } else {
                Text("Not allowed yet").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                if denied { Button("Open System Settings") { NSWorkspace.shared.open(URL(string: settings)!) } }
                else { Button(allow, action: request).buttonStyle(.borderedProminent) }
            }
        }
        .padding(12)
        .background(cardColor, in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: download

/// Downloads the speech model into <data>/models (unless the app already has it), then lets FluidAudio fetch the speaker model.
final class ModelDownload: NSObject, ObservableObject, URLSessionDownloadDelegate {
    @Published var progress = 0.0
    @Published var received: Int64 = 0
    @Published var total: Int64 = 0
    @Published var speechDone = Store.speechModel != nil
    @Published var speakersDone = false
    @Published var error: String?
    private var session: URLSession?
    private var started = false

    var allDone: Bool { speechDone && speakersDone }
    var speechDetail: String {
        total > 0 ? "\(received / 1_000_000) of \(total / 1_000_000) MB" : "Starting..."
    }

    func start() {
        guard !started || error != nil else { return }
        started = true; error = nil
        if speechDone { fetchSpeakers(); return }
        let s = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        session = s
        s.downloadTask(with: Store.speechModelURL).resume()
    }

    /// FluidAudio downloads its model the first time a diarizer is made; making one now saves the wait at the first meeting.
    private func fetchSpeakers() {
        Task { @MainActor in
            do { _ = try await LSEENDDiarizer(variant: .ami, stepSize: .step500ms); speakersDone = true }
            catch { self.error = "Speaker model: \(error.localizedDescription)" }
        }
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        received = totalBytesWritten; total = totalBytesExpectedToWrite
        progress = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
    }

    /// The temporary file is gone once this returns, so move it here.
    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let dest = Store.speechModelFile, fm = FileManager.default
        if let code = (downloadTask.response as? HTTPURLResponse)?.statusCode, code != 200 { error = "Download failed (HTTP \(code))"; return }
        do {
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: dest)
            try fm.moveItem(at: location, to: dest)
            speechDone = true
            fetchSpeakers()
        } catch {
            self.error = "Could not save the model: \(error.localizedDescription)"
        }
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError e: Error?) {
        if let e { error = "Download stopped: \(e.localizedDescription)" }
    }
}
