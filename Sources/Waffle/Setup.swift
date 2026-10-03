// The first-run setup, as a sheet over the main window: welcome, the speech models download, microphone and system audio
// permissions, the AI provider, done. Each step is one page with a big icon; Settings has everything again later.
import AVFoundation
import FluidAudio
import SwiftUI

enum SetupStep: Int, CaseIterable { case welcome, models, microphone, systemAudio, calendar, ai, done }

struct SetupView: View {
    @EnvironmentObject var model: Model
    @StateObject var download = ModelDownload()
    @State var step = UserDefaults.standard.bool(forKey: "setupDone") ? SetupStep.models : .welcome  // shown again after an update: the new models
    @State var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State var audioStatus = SystemAudioPermission.status
    @State var calendarAllowed = Agenda.allowed

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case .welcome: welcome
                case .models: models
                case .microphone: microphone
                case .systemAudio: systemAudio
                case .calendar: calendar
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
                audioStatus = SystemAudioPermission.status
                calendarAllowed = Agenda.allowed
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
        SetupPage(title: "Download the speech models", text: "Waffle recognises speech on your Mac, so it needs its models once: about 750 MB. They stay on this Mac and run on its Neural Engine.") {
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
        SetupPage(title: "Allow system audio", text: "So Waffle hears the other people in the call. macOS calls this System Audio Recording: Waffle gets the sound only, never the screen.") {
            HeroIcon(symbol: "speaker.wave.2.fill", colors: [.teal, .blue])
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                PermissionRow(granted: audioStatus == .allowed, denied: audioStatus == .denied, allow: "Allow System Audio",
                              settings: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    SystemAudioPermission.request { _ in audioStatus = SystemAudioPermission.status }
                }
                Text("In System Settings it is under Privacy & Security > Screen & System Audio Recording, in System Audio Recording Only.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    var calendar: some View {
        SetupPage(title: "Use your calendar (optional)", text: "Waffle takes the meeting's title and the people invited from the event going on, so notes get the right title and names.") {
            HeroIcon(symbol: "calendar", colors: [.red, .orange])
        } content: {
            PermissionRow(granted: calendarAllowed, denied: Agenda.denied, allow: "Allow Calendar",
                          settings: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                Task { calendarAllowed = await Agenda.request() }
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

/// Downloads the models from Hugging Face once (FluidAudio keeps them in ~/Library/Application Support/FluidAudio): speech recognition,
/// then voice detection and the speaker models. Removes the speech model of versions before 0.4.
final class ModelDownload: ObservableObject {
    @Published var progress = 0.0
    @Published var speechDetail = "Starting..."
    @Published var speechDone = Engine.downloaded
    @Published var speakersDone = false
    @Published var error: String?
    private var started = false

    var allDone: Bool { speechDone && speakersDone }

    func start() {
        guard !started || error != nil else { return }
        started = true; error = nil
        Task { @MainActor in
            do {
                if !speechDone {
                    _ = try await AsrModels.download(version: Engine.asrVersion) { [weak self] p in
                        DispatchQueue.main.async {
                            self?.progress = p.fractionCompleted
                            switch p.phase {
                            case .listing: self?.speechDetail = "Starting..."
                            case .downloading: self?.speechDetail = "\(Int(p.fractionCompleted * 100))%"
                            case .compiling: self?.speechDetail = "Preparing for this Mac..."
                            }
                        }
                    }
                    speechDone = true
                    try? FileManager.default.removeItem(at: Store.oldModels)
                }
            } catch {
                self.error = "Speech model: \(error.localizedDescription)"
                return
            }
            do {
                _ = try await VadManager(config: .default)
                _ = try await LSEENDDiarizer(variant: .ami, stepSize: .step500ms)
                try await OfflineDiarizerManager().prepareModels()
                speakersDone = true
            } catch {
                self.error = "Speaker models: \(error.localizedDescription)"
            }
        }
    }
}
