// Summaries and answers through the AI command line tool the user already has and is signed in to: Claude Code (`claude -p`) or
// Codex (`codex exec`). No API key, nothing to pay for beyond the user's own plan.
import Foundation

enum Provider: String, CaseIterable, Identifiable {
    case claude, codex
    var id: String { rawValue }
    var name: String { self == .claude ? "Claude Code" : "Codex" }
    /// Where to get the tool.
    var site: URL { URL(string: self == .claude ? "https://claude.com/claude-code" : "https://developers.openai.com/codex/cli")! }
    /// Signs in in Terminal (a browser page opens).
    var loginCommand: String { self == .claude ? "claude auth login" : "codex login" }

    /// The one Settings or onboarding picked; until then Claude Code.
    static var current: Provider {
        get { Provider(rawValue: UserDefaults.standard.string(forKey: "provider") ?? "") ?? .claude }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "provider") }
    }
}

struct AIAccount {
    var installed = true, loggedIn = false
    var detail: String?  // "you@example.com · Claude Max plan", "Signed in with ChatGPT"
}

enum AI {
    /// Apps started from Finder get a bare PATH: use the Terminal PATH build.sh saved, plus the usual install places.
    static let path = [Bundle.main.object(forInfoDictionaryKey: "BuildPath") as? String, "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"]
        .compactMap { $0 }.joined(separator: ":")

    /// Runs `<tool> <args>` and waits. Exit code 127 means the tool was not found.
    static func run(_ tool: String, _ args: [String], stdin: String = "", cwd: URL? = nil, timeout: TimeInterval = 900) -> (code: Int32, out: String, err: String) {
        let p = Process(), inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = [tool] + args
        p.environment = ProcessInfo.processInfo.environment.merging(["PATH": path]) { $1 }
        p.currentDirectoryURL = cwd
        p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = errPipe
        do { try p.run() } catch { return (127, "", error.localizedDescription) }
        DispatchQueue.global().async {  // the context can be bigger than a pipe buffer: write it while we read
            try? inPipe.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
            try? inPipe.fileHandleForWriting.close()
        }
        var err = Data()
        let errDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { err = errPipe.fileHandleForReading.readDataToEndOfFile(); errDone.signal() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        errDone.wait()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self))
    }

    /// A pure text call with the chosen provider: instructions, a request, and the meeting text on stdin. Neither tool gets the user's
    /// own hooks, plugins or config (Claude: `--setting-sources project`, Codex: `--ignore-user-config`), and Codex runs in a read-only
    /// sandbox in an empty folder.
    static func ask(system: String, prompt: String, context: String, cwd: URL) throws -> String {
        let p = Provider.current
        let r: (code: Int32, out: String, err: String)
        var answer: String
        switch p {
        case .claude:
            r = run("claude", ["-p", prompt, "--model", Store.claudeModel, "--system-prompt", system, "--tools", "", "--setting-sources", "project", "--no-session-persistence"], stdin: context, cwd: cwd)
            answer = r.out
        case .codex:
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("waffle-codex-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let out = dir.appendingPathComponent("answer.md")
            r = run("codex", ["exec", "--skip-git-repo-check", "--ephemeral", "--ignore-user-config", "--ignore-rules", "-s", "read-only", "-C", dir.path,
                              "--color", "never", "-c", "developer_instructions=\(tomlString(system))", "-o", out.path, prompt], stdin: context, cwd: dir)
            answer = (try? String(contentsOf: out, encoding: .utf8)) ?? r.out
        }
        guard r.code == 0 else {
            let why = r.code == 127 ? "\(p.name) is not installed" : (r.err.isEmpty ? r.out : r.err).trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(domain: p.rawValue, code: Int(r.code), userInfo: [NSLocalizedDescriptionKey: String(why.suffix(500))])
        }
        answer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        return answer
    }

    /// A TOML basic string for `codex -c key=value`: JSON's escapes are TOML's, as long as "/" is left alone.
    static func tomlString(_ s: String) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = .withoutEscapingSlashes
        return (try? String(decoding: enc.encode(s), as: UTF8.self)) ?? "\"\""
    }

    private static var cached: [Provider: (at: Date, value: AIAccount)] = [:]
    private static let cacheLock = NSLock()

    /// Whether a provider's tool is installed and signed in, for Settings and onboarding. Cached for 30 s: the tools take a moment.
    static func account(_ p: Provider, fresh: Bool = false) -> AIAccount {
        cacheLock.lock()
        if !fresh, let c = cached[p], Date().timeIntervalSince(c.at) < 30 { cacheLock.unlock(); return c.value }
        cacheLock.unlock()
        var a: AIAccount
        switch p {
        case .claude:
            let r = run("claude", ["auth", "status", "--json"], timeout: 30)
            a = AIAccount(installed: r.code != 127)
            if let info = (try? JSONSerialization.jsonObject(with: Data(r.out.utf8))) as? [String: Any] {
                a.loggedIn = info["loggedIn"] as? Bool ?? false
                let plan = (info["subscriptionType"] as? String).map { "Claude \($0.prefix(1).uppercased() + $0.dropFirst()) plan" }
                a.detail = [info["email"] as? String, plan].compactMap { $0 }.joined(separator: " · ")
            }
        case .codex:
            let r = run("codex", ["login", "status"], timeout: 30)
            a = AIAccount(installed: r.code != 127, loggedIn: r.code == 0)
            let said = (r.out + r.err).trimmingCharacters(in: .whitespacesAndNewlines)
            a.detail = said.hasPrefix("Logged in using ") ? "Signed in with " + said.dropFirst("Logged in using ".count) : nil
        }
        cacheLock.lock(); cached[p] = (Date(), a); cacheLock.unlock()
        return a
    }

    static func logout(_ p: Provider) { _ = run(p.rawValue, p == .claude ? ["auth", "logout"] : ["logout"], timeout: 30) }
}
