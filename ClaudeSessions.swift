import Cocoa

// MARK: - Localization

// The app follows the Mac's language: Italian when the system's preferred
// language is Italian, English otherwise (default fallback).
enum Lang { case it, en }

let appLang: Lang = {
    // Explicit override (mainly for demo/promo rendering): --lang=it / --lang=en
    if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--lang=") }) {
        return arg.hasSuffix("it") ? .it : .en
    }
    let pref = Locale.preferredLanguages.first ?? "en"
    return pref.hasPrefix("it") ? .it : .en
}()

enum L {
    /// Pick the string matching the current app language.
    static func t(_ it: String, _ en: String) -> String { appLang == .it ? it : en }
}

// MARK: - Models

struct ProcInfo {
    let pid: Int
    let ppid: Int
    let command: String
}

enum SessionState: String {
    case working
    case waiting   // Claude is asking something / needs permission
    case done      // finished, ready for next prompt
    case unknown   // no state file yet (hooks not active for this session)

    var dot: String {
        switch self {
        case .working: return "🟢"
        case .waiting: return "🟡"
        case .done:    return "⚪️"
        case .unknown: return "⚫️"
        }
    }

    var label: String {
        switch self {
        case .working: return L.t("sta lavorando", "working")
        case .waiting: return L.t("ti sta chiedendo qualcosa", "waiting for you")
        case .done:    return L.t("ha finito", "done")
        case .unknown: return L.t("stato sconosciuto", "unknown")
        }
    }

    // ordering for menu-bar attention: waiting > working > done > unknown
    var priority: Int {
        switch self {
        case .waiting: return 3
        case .working: return 2
        case .done:    return 1
        case .unknown: return 0
        }
    }
}

struct Session {
    let pid: Int
    let appName: String
    let appPath: String?   // /Applications/X.app  (for icon + activation)
    let cwd: String
    var state: SessionState
    var event: String?
    var tool: String?
    var message: String?
    var ts: Date?
}

// Injected by --demo modes so the menu/toasts show clean, fake sessions
// instead of the real ones (keeps private project names out of promo material).
var demoSessions: [Session]? = nil

// MARK: - Scanner

final class SessionScanner {

    private let stateDir = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/session-state")
    private let home = NSHomeDirectory()

    // Friendly display names for a few bundles whose folder name isn't ideal.
    private let nameAliases: [String: String] = [
        "Visual Studio Code": "VS Code",
        "Visual Studio Code - Insiders": "VS Code Insiders",
        "Electron": "Electron app"
    ]

    func scan() -> [Session] {
        if let demo = demoSessions { return demo }
        let procs = psSnapshot()
        var byPid: [Int: ProcInfo] = [:]
        for p in procs { byPid[p.pid] = p }

        // claude processes: command's first token basename == "claude"
        let claudeProcs = procs.filter { firstTokenBasename($0.command) == "claude" }

        // pid -> state info from hook files
        let states = readStateFiles()

        var sessions: [Session] = []
        for cp in claudeProcs {
            let (appName, appPath) = resolveHostApp(pid: cp.pid, byPid: byPid)
            var cwd = lsofCwd(pid: cp.pid)
            if cwd.isEmpty { cwd = states[cp.pid]?.cwd ?? "" }

            var st = SessionState.unknown
            var ev: String? = nil
            var tool: String? = nil
            var message: String? = nil
            var ts: Date? = nil
            if let s = states[cp.pid] {
                st = s.state
                ev = s.event
                tool = s.tool
                message = s.message
                ts = s.ts
            }

            sessions.append(Session(pid: cp.pid, appName: appName, appPath: appPath,
                                    cwd: cwd, state: st, event: ev, tool: tool, message: message, ts: ts))
        }

        // stable sort: attention first, then app name
        sessions.sort {
            if $0.state.priority != $1.state.priority { return $0.state.priority > $1.state.priority }
            return $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending
        }
        return sessions
    }

    // MARK: process tree

    private func resolveHostApp(pid: Int, byPid: [Int: ProcInfo]) -> (String, String?) {
        var cur = pid
        for _ in 0..<20 {
            guard let p = byPid[cur] else { break }
            // A GUI app process has "<Bundle>.app/Contents/MacOS/<exe>" in its command.
            if p.command.range(of: ".app/Contents/MacOS/") != nil,
               let firstApp = p.command.range(of: ".app/") {
                // Outermost bundle = everything up to the first ".app/" (handles nested
                // helpers like ".../Visual Studio Code.app/.../Code Helper.app/...").
                let bundlePath = String(p.command[..<firstApp.lowerBound]) + ".app"
                var name = (bundlePath as NSString).lastPathComponent
                if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
                return (nameAliases[name] ?? name, bundlePath)
            }
            if p.ppid <= 1 { break }
            cur = p.ppid
        }
        // Reached launchd/tmux without a GUI ancestor (e.g. detached tmux session).
        return (L.t("Terminale", "Terminal"), nil)
    }

    // MARK: helpers

    private func firstTokenBasename(_ command: String) -> String {
        let first = command.split(separator: " ", maxSplits: 1).first.map(String.init) ?? command
        return (first as NSString).lastPathComponent
    }

    private func psSnapshot() -> [ProcInfo] {
        let out = run("/bin/ps", ["-axo", "pid=,ppid=,command="])
        var result: [ProcInfo] = []
        for raw in out.split(separator: "\n") {
            var s = Substring(raw)
            s = s.drop(while: { $0 == " " })
            guard let sp1 = s.firstIndex(of: " "), let pid = Int(s[..<sp1]) else { continue }
            var rest = s[s.index(after: sp1)...].drop(while: { $0 == " " })
            guard let sp2 = rest.firstIndex(of: " "), let ppid = Int(rest[..<sp2]) else { continue }
            let command = String(rest[rest.index(after: sp2)...].drop(while: { $0 == " " }))
            result.append(ProcInfo(pid: pid, ppid: ppid, command: command))
        }
        return result
    }

    private func lsofCwd(pid: Int) -> String {
        let out = run("/usr/sbin/lsof", ["-a", "-d", "cwd", "-p", "\(pid)", "-Fn"])
        for line in out.split(separator: "\n") where line.hasPrefix("n") {
            return String(line.dropFirst())
        }
        return ""
    }

    struct StateRecord { let pid: Int; let cwd: String; let state: SessionState; let event: String?; let tool: String?; let message: String?; let ts: Date? }

    private func readStateFiles() -> [Int: StateRecord] {
        var map: [Int: StateRecord] = [:]
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: stateDir) else { return map }
        for f in files where f.hasSuffix(".json") {
            let path = (stateDir as NSString).appendingPathComponent(f)
            guard let data = fm.contents(atPath: path),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = obj["pid"] as? Int else { continue }
            let state = SessionState(rawValue: (obj["state"] as? String) ?? "unknown") ?? .unknown
            let cwd = (obj["cwd"] as? String) ?? ""
            let event = obj["event"] as? String
            let tool = obj["tool"] as? String
            let message = (obj["message"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            var ts: Date? = nil
            if let t = obj["ts"] as? Double { ts = Date(timeIntervalSince1970: t) }
            map[pid] = StateRecord(pid: pid, cwd: cwd, state: state, event: event, tool: tool, message: message, ts: ts)
        }
        return map
    }

    func prettyPath(_ path: String) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}

// MARK: - shell

@discardableResult
func run(_ launchPath: String, _ args: [String]) -> String {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: launchPath)
    task.arguments = args
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = Pipe()
    do { try task.run() } catch { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private let scanner = SessionScanner()
    private let toasts = ToastManager()
    private var timer: Timer?
    private var openTimer: Timer?
    private var lastSignature = ""
    private var cachedSessions: [Session] = []
    private var lastStateByPid: [Int: SessionState] = [:]
    private var primed = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single instance: if another copy already owns the menu bar, bow out.
        let myPid = ProcessInfo.processInfo.processIdentifier
        let myBundle = Bundle.main.bundleURL.standardizedFileURL
        let others = NSWorkspace.shared.runningApplications.filter { app in
            app.processIdentifier != myPid &&
            (app.bundleIdentifier == "com.christiancannata.claudesessions" ||
             app.bundleURL?.standardizedFileURL == myBundle)
        }
        if !others.isEmpty {
            NSApp.terminate(nil)
            return
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func refresh() {
        cachedSessions = scanner.scan()
        detectTransitions()
        updateStatusButton()
    }

    // Demo helper: programmatically drop the menu open so an external
    // screencapture can grab it. Blocks until the menu is dismissed.
    func openMenuForDemo() {
        statusItem?.button?.performClick(nil)
    }

    // MARK: - Notifications on state change

    private func detectTransitions() {
        var current: [Int: SessionState] = [:]
        for s in cachedSessions { current[s.pid] = s.state }

        // first pass after launch: record states without notifying for pre-existing sessions
        if !primed {
            lastStateByPid = current
            primed = true
            return
        }

        for s in cachedSessions {
            let prev = lastStateByPid[s.pid]
            let headline = "\(s.appName) · \(scanner.prettyPath(s.cwd))"
            if s.state == .waiting && prev != .waiting {
                notifyUser(headline: headline,
                           detail: s.message ?? L.t("ti sta chiedendo qualcosa", "is asking you something"),
                           color: .systemYellow, sound: "Submarine", appPath: s.appPath)
            } else if s.state == .done && prev == .working {
                notifyUser(headline: headline, detail: L.t("ha finito di lavorare", "finished working"),
                           color: .systemGreen, sound: "Glass", appPath: s.appPath)
            }
        }
        lastStateByPid = current
    }

    private func notifyUser(headline: String, detail: String, color: NSColor, sound: String, appPath: String?) {
        toasts.show(headline: headline, detail: detail, accent: color, appPath: appPath)
        if soundsEnabled { playSound(sound) }
    }

    private func playSound(_ name: String) {
        let path = "/System/Library/Sounds/\(name).aiff"
        guard FileManager.default.fileExists(atPath: path) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        p.arguments = [path]
        try? p.run()
    }

    private func updateStatusButton() {
        guard let button = statusItem.button else { return }
        let count = cachedSessions.count
        let needsAttention = cachedSessions.contains(where: { $0.state == .waiting })

        let symbolName = needsAttention ? "bell.badge.fill" : "bell.fill"
        var cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        if needsAttention {
            cfg = cfg.applying(.init(hierarchicalColor: .systemYellow))
        }
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Claude")?
            .withSymbolConfiguration(cfg)
        // template = adapts to the menu bar (black/white); non-template keeps the yellow tint.
        image?.isTemplate = !needsAttention
        button.image = image
        button.imagePosition = count > 0 ? .imageLeft : .imageOnly
        button.imageHugsTitle = true   // pull the number right up against the bell
        if count > 0 {
            let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
            button.attributedTitle = NSAttributedString(
                string: "\(count)",
                attributes: [.font: font, .baselineOffset: 4])
        } else {
            button.title = ""
        }
    }

    // A fingerprint of what's shown; drives live rebuilds only on real changes.
    private func signature() -> String {
        cachedSessions.map { "\($0.pid):\($0.state.rawValue):\($0.cwd):\($0.tool ?? "")" }
            .joined(separator: "|")
    }

    // Called right before the menu opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
        lastSignature = signature()
        rebuild(menu)
    }

    // While the menu is open, poll and re-render live — but only when something changed,
    // so open submenus and highlighting aren't disrupted needlessly.
    func menuWillOpen(_ menu: NSMenu) {
        openTimer?.invalidate()
        openTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self, weak menu] _ in
            guard let self = self, let menu = menu else { return }
            self.refresh()
            let sig = self.signature()
            if sig != self.lastSignature {
                self.lastSignature = sig
                self.rebuild(menu)
            }
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        openTimer?.invalidate()
        openTimer = nil
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()

        let n = cachedSessions.count
        let headerTitle: String
        if n == 0 {
            headerTitle = L.t("Nessuna sessione Claude attiva", "No active Claude sessions")
        } else {
            headerTitle = L.t(
                "Claude — \(n) sessione\(n == 1 ? "" : "i") attiv\(n == 1 ? "a" : "e")",
                "Claude — \(n) active session\(n == 1 ? "" : "s")")
        }
        let header = NSMenuItem(title: headerTitle, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        for (idx, s) in cachedSessions.enumerated() {
            let project = scanner.prettyPath(s.cwd)
            let title = "\(s.state.dot)  \(s.appName)   —   \(project)"
            let item = NSMenuItem(title: title, action: #selector(activateSession(_:)), keyEquivalent: "")
            item.target = self
            item.tag = idx
            if let p = s.appPath {
                let icon = NSWorkspace.shared.icon(forFile: p)
                icon.size = NSSize(width: 18, height: 18)
                item.image = icon
            }
            // detail submenu
            let sub = NSMenu()
            var detail = "\(s.state.label)"
            if s.state == .working, let tool = s.tool { detail += " · \(tool)" }
            if let ts = s.ts { detail += "  (\(relative(ts)))" }
            let d = NSMenuItem(title: detail, action: nil, keyEquivalent: "")
            d.isEnabled = false
            sub.addItem(d)
            // what Claude is asking, when waiting
            if s.state == .waiting, let msg = s.message, !msg.isEmpty {
                let m = NSMenuItem(title: "“\(msg)”", action: nil, keyEquivalent: "")
                m.isEnabled = false
                sub.addItem(m)
            }
            sub.addItem(NSMenuItem(title: "pid \(s.pid)", action: nil, keyEquivalent: ""))
            let openFolder = NSMenuItem(title: L.t("Apri cartella nel Finder", "Open folder in Finder"), action: #selector(openFolder(_:)), keyEquivalent: "")
            openFolder.target = self
            openFolder.tag = idx
            sub.addItem(openFolder)
            item.submenu = sub
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let soundsItem = NSMenuItem(title: L.t("Suoni di notifica", "Notification sounds"), action: #selector(toggleSounds(_:)), keyEquivalent: "")
        soundsItem.target = self
        soundsItem.state = soundsEnabled ? .on : .off
        menu.addItem(soundsItem)

        let loginItem = NSMenuItem(title: L.t("Avvia al login", "Launch at login"), action: #selector(toggleLogin(_:)), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = loginEnabled ? .on : .off
        menu.addItem(loginItem)

        let quit = NSMenuItem(title: L.t("Esci", "Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private var soundsDisabledURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/session-state/sounds.disabled")
    }
    private var soundsEnabled: Bool {
        !FileManager.default.fileExists(atPath: soundsDisabledURL.path)
    }

    @objc private func toggleSounds(_ sender: NSMenuItem) {
        let fm = FileManager.default
        if soundsEnabled {
            try? FileManager.default
                .createDirectory(at: soundsDisabledURL.deletingLastPathComponent(),
                                 withIntermediateDirectories: true)
            try? Data().write(to: soundsDisabledURL)   // create flag -> muted
        } else {
            try? fm.removeItem(at: soundsDisabledURL)   // remove flag -> on
        }
        sender.state = soundsEnabled ? .on : .off
    }

    // MARK: - Launch at login (LaunchAgent)

    private let loginLabel = "com.christiancannata.claudesessions"
    private var loginPlistURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents/\(loginLabel).plist")
    }
    private var loginEnabled: Bool {
        FileManager.default.fileExists(atPath: loginPlistURL.path)
    }

    @objc private func toggleLogin(_ sender: NSMenuItem) {
        if loginEnabled {
            run("/bin/launchctl", ["unload", loginPlistURL.path])
            try? FileManager.default.removeItem(at: loginPlistURL)
        } else {
            let exe = Bundle.main.executableURL?.path
                ?? CommandLine.arguments.first ?? ""
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
              <key>Label</key><string>\(loginLabel)</string>
              <key>ProgramArguments</key>
              <array><string>\(exe)</string></array>
              <key>RunAtLoad</key><true/>
            </dict>
            </plist>
            """
            try? FileManager.default.createDirectory(
                at: loginPlistURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try? plist.write(to: loginPlistURL, atomically: true, encoding: .utf8)
            run("/bin/launchctl", ["load", loginPlistURL.path])
        }
        sender.state = loginEnabled ? .on : .off
    }

    private func relative(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        if s < 5 { return L.t("ora", "now") }
        if s < 60 { return L.t("\(s)s fa", "\(s)s ago") }
        if s < 3600 { return L.t("\(s/60)m fa", "\(s/60)m ago") }
        return L.t("\(s/3600)h fa", "\(s/3600)h ago")
    }

    @objc private func activateSession(_ sender: NSMenuItem) {
        guard sender.tag < cachedSessions.count else { return }
        let s = cachedSessions[sender.tag]
        guard let p = s.appPath else { return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: p), configuration: cfg)
    }

    @objc private func openFolder(_ sender: NSMenuItem) {
        guard sender.tag < cachedSessions.count else { return }
        let s = cachedSessions[sender.tag]
        guard !s.cwd.isEmpty else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: s.cwd))
    }
}

// MARK: - In-app toast (independent of macOS Notification Center)

private final class ToastView: NSView {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }
    override var acceptsFirstResponder: Bool { true }
}

final class ToastManager {
    private var active: [NSPanel] = []
    private let width: CGFloat = 360
    private let height: CGFloat = 76
    private let gap: CGFloat = 8
    private let margin: CGFloat = 12
    private let lifetime: TimeInterval = 6

    func show(headline: String, detail: String, accent: NSColor, appPath: String?) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.ignoresMouseEvents = false

        // blurred rounded background
        let blur = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        blur.material = .hudWindow
        blur.state = .active
        blur.blendingMode = .behindWindow
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 14
        blur.layer?.masksToBounds = true

        let container = ToastView(frame: blur.bounds)
        container.autoresizingMask = [.width, .height]

        // host app icon (the "where") with a coloured state dot badge
        let iconSize: CGFloat = 32
        let iconView = NSImageView(frame: NSRect(x: 14, y: height/2 - iconSize/2, width: iconSize, height: iconSize))
        if let appPath = appPath {
            iconView.image = NSWorkspace.shared.icon(forFile: appPath)
        }
        let badge = NSView(frame: NSRect(x: 14 + iconSize - 11, y: height/2 - iconSize/2, width: 12, height: 12))
        badge.wantsLayer = true
        badge.layer?.backgroundColor = accent.cgColor
        badge.layer?.cornerRadius = 6
        badge.layer?.borderWidth = 1.5
        badge.layer?.borderColor = NSColor.windowBackgroundColor.cgColor

        let textX: CGFloat = 14 + iconSize + 12
        let textW = width - textX - 14

        let titleLabel = NSTextField(labelWithString: headline)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.frame = NSRect(x: textX, y: 40, width: textW, height: 18)

        let subLabel = NSTextField(labelWithString: detail)
        subLabel.font = .systemFont(ofSize: 11)
        subLabel.textColor = .secondaryLabelColor
        subLabel.lineBreakMode = .byTruncatingTail
        subLabel.frame = NSRect(x: textX, y: 16, width: textW, height: 18)

        container.addSubview(iconView)
        container.addSubview(badge)
        container.addSubview(titleLabel)
        container.addSubview(subLabel)
        blur.addSubview(container)
        panel.contentView = blur

        container.onClick = { [weak self, weak panel] in
            if let appPath = appPath {
                let cfg = NSWorkspace.OpenConfiguration()
                cfg.activates = true
                NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: appPath), configuration: cfg)
            }
            if let panel = panel { self?.dismiss(panel) }
        }

        active.insert(panel, at: 0)
        layout()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            panel.animator().alphaValue = 1
        }

        Timer.scheduledTimer(withTimeInterval: lifetime, repeats: false) { [weak self, weak panel] _ in
            if let panel = panel { self?.dismiss(panel) }
        }
    }

    private func dismiss(_ panel: NSPanel) {
        guard active.contains(where: { $0 === panel }) else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            panel.orderOut(nil)
            self?.active.removeAll { $0 === panel }
            self?.layout()
        })
    }

    // stack toasts down from the top-right of the main screen
    private func layout() {
        guard let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        for (i, panel) in active.enumerated() {
            let x = vf.maxX - width - margin
            let y = vf.maxY - height - margin - CGFloat(i) * (height + gap)
            panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true, animate: true)
        }
    }
}

// CLI test: `ClaudeSessions --toast-test` shows a toast for 8s (bypasses single-instance).
if CommandLine.arguments.contains("--toast-test") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let mgr = ToastManager()
    DispatchQueue.main.async {
        mgr.show(headline: "TEST · ~/progetto",
                 detail: "Se vedi questo, il rendering funziona",
                 accent: .systemYellow, appPath: "/System/Applications/Utilities/Terminal.app")
    }
    Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { _ in NSApp.terminate(nil) }
    app.run()
    exit(0)
}

// CLI debug mode: `ClaudeSessions --scan` prints sessions and exits.
if CommandLine.arguments.contains("--scan") {
    let sc = SessionScanner()
    let sessions = sc.scan()
    if sessions.isEmpty { print(L.t("Nessuna sessione Claude attiva.", "No active Claude sessions.")) }
    for s in sessions {
        print("\(s.state.dot) \(s.appName)  [\(s.state.label)]  \(sc.prettyPath(s.cwd))  pid \(s.pid)")
    }
    exit(0)
}

// MARK: - Demo / promo rendering
//
// Fake but realistic sessions used by the --demo-* modes so the promo
// material never shows real project paths.
func demoMockSessions() -> [Session] {
    let home = NSHomeDirectory()
    return [
        Session(pid: 4821, appName: "WebStorm",
                appPath: "/Applications/WebStorm.app",
                cwd: home + "/projects/checkout-api", state: .waiting,
                event: nil, tool: nil,
                message: L.t("Posso eseguire `npm run migrate`?", "Can I run `npm run migrate`?"),
                ts: Date().addingTimeInterval(-8)),
        Session(pid: 3390, appName: "iTerm",
                appPath: "/Applications/iTerm.app",
                cwd: home + "/blog", state: .working,
                event: nil, tool: "Edit", message: nil,
                ts: Date().addingTimeInterval(-3)),
        Session(pid: 2077, appName: L.t("Terminale", "Terminal"),
                appPath: "/System/Applications/Utilities/Terminal.app",
                cwd: home + "/api-server", state: .done,
                event: nil, tool: nil, message: nil,
                ts: Date().addingTimeInterval(-42)),
    ]
}

// Full-screen gradient backdrop for promo captures: hides the real desktop
// (privacy) and gives the menu/toasts a clean, branded background. Sits above
// other apps' windows but below the status menu (level ~101) and toasts (25).
var demoBGWindow: NSWindow?
func showDemoBackground() {
    guard let screen = NSScreen.main else { return }
    let w = NSWindow(contentRect: screen.frame, styleMask: [.borderless],
                     backing: .buffered, defer: false)
    // Just above normal app windows (covers the real desktop) but well below
    // the toasts (.statusBar) and the status menu, so those render on top.
    w.level = NSWindow.Level(rawValue: 1)
    w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    w.isOpaque = true
    w.ignoresMouseEvents = true

    let v = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
    v.wantsLayer = true
    let g = CAGradientLayer()
    g.frame = v.bounds
    g.colors = [
        NSColor(calibratedRed: 0.09, green: 0.09, blue: 0.20, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.28, green: 0.18, blue: 0.55, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.49, green: 0.24, blue: 0.62, alpha: 1).cgColor,
    ]
    g.startPoint = CGPoint(x: 0, y: 1)
    g.endPoint = CGPoint(x: 1, y: 0)
    v.layer?.addSublayer(g)
    w.contentView = v
    w.orderFrontRegardless()
    demoBGWindow = w
}

// `--demo-menu`: show the bell with a badge and drop the menu open, then wait
// (an external screencapture grabs the still; the process is killed afterwards).
if CommandLine.arguments.contains("--demo-menu") {
    demoSessions = demoMockSessions()
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showDemoBackground() }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        delegate.openMenuForDemo()
    }
    app.run()
    exit(0)
}

// `--demo-toasts`: play the two notification toasts (waiting → done) in sequence
// so an external screen recording can capture the animation.
if CommandLine.arguments.contains("--demo-toasts") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let mgr = ToastManager()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { showDemoBackground() }
    let yellow = NSColor.systemYellow
    let green = NSColor.systemGreen

    // A curated sequence of good-looking example notifications: they arrive
    // staggered so they stack, showing off both states (needs-you / done).
    struct Demo { let at: Double; let head: String; let detail: String; let color: NSColor; let app: String }
    let vscode = "/Applications/WebStorm.app"
    let iterm  = "/Applications/iTerm.app"
    let term   = "/System/Applications/Utilities/Terminal.app"
    let seq: [Demo] = [
        Demo(at: 0.6, head: "WebStorm · ~/checkout-api",
             detail: L.t("Posso eseguire `npm run migrate`?", "Can I run `npm run migrate`?"),
             color: yellow, app: vscode),
        Demo(at: 2.2, head: "iTerm · ~/blog",
             detail: L.t("ha finito di lavorare", "finished working"),
             color: green, app: iterm),
        Demo(at: 3.8, head: L.t("Terminale", "Terminal") + " · ~/api-server",
             detail: L.t("Vuoi che faccia il commit di 12 file?", "Want me to commit 12 files?"),
             color: yellow, app: term),
    ]
    for d in seq {
        DispatchQueue.main.asyncAfter(deadline: .now() + d.at) {
            mgr.show(headline: d.head, detail: d.detail, accent: d.color, appPath: d.app)
        }
    }
    Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { _ in NSApp.terminate(nil) }
    app.run()
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // menu-bar only, no Dock icon
let delegate = AppDelegate()
app.delegate = delegate
app.run()
