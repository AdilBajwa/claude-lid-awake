// Menu bar icon for lid-awake.
// Polls `lid-awake.sh status` every 10 s and shows what it is doing.
// Build: swiftc -O menubar/LidAwakeMenu.swift -o LidAwakeMenu   (install.sh does this)

import AppKit

let home = FileManager.default.homeDirectoryForCurrentUser.path
let dir = ProcessInfo.processInfo.environment["LID_AWAKE_DIR"] ?? "\(home)/.claude/lid-awake"
let script = "\(dir)/lid-awake.sh"

func run(_ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = [script] + args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return "" }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

// How long "closed 2h 14m" stays next to the icon after the lid opens.
let showAfterOpenSecs = 300

struct Closure {
    var start = 0
    var end: Int?
    var awake = 0
    var tasks: [(secs: Int, result: String, cwd: String)] = []
}

func loadHistory() -> [Closure] {
    var closures: [Closure] = []
    for line in run(["history"]).split(separator: "\n") {
        let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { continue }
        if parts[0] == "start" { closures.append(Closure(start: Int(parts[1]) ?? 0)); continue }
        guard !closures.isEmpty else { continue }
        let last = closures.count - 1
        switch parts[0] {
        case "end": closures[last].end = Int(parts[1])
        case "awake": closures[last].awake = Int(parts[1]) ?? 0
        case "task":
            // <secs>|<result>|<session>|<cwd>
            let t = parts[1].split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            if t.count == 4 { closures[last].tasks.append((Int(t[0]) ?? 0, t[1], t[3])) }
        default: break
        }
    }
    return closures
}

func clock(_ epoch: Int) -> String {
    DateFormatter.localizedString(from: Date(timeIntervalSince1970: TimeInterval(epoch)), dateStyle: .none, timeStyle: .short)
}

func dayName(_ epoch: Int) -> String {
    let f = DateFormatter()
    f.dateStyle = .medium
    f.timeStyle = .none
    f.doesRelativeDateFormatting = true
    return f.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
}

func duration(_ secs: Int) -> String {
    if secs < 60 { return "\(secs)s" }
    let h = secs / 3600, m = (secs % 3600) / 60
    return h > 0 ? "\(h)h \(m)m" : "\(m)m"
}

final class App: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var status: [String: String] = [:]
    var history: [Closure] = []

    func applicationDidFinishLaunching(_ note: Notification) {
        refresh()
        // Opening the lid wakes the Mac: show the closed time right away.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func int(_ key: String) -> Int { Int(status[key] ?? "") ?? 0 }

    func refresh() {
        status = [:]
        for line in run(["status"]).split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { status[parts[0]] = parts[1] }
        }
        history = loadHistory()

        let symbol: String
        let tip: String
        if status["holding"] == "1" && int("working") > 0 {
            symbol = "cup.and.saucer.fill"; tip = "Holding Mac awake"
        } else if status["holding"] == "1" {
            symbol = "hourglass"; tip = int("waiting") > 0 ? "Waiting on you" : "Finished, sleeps soon if the lid is closed"
        } else {
            symbol = "moon.zzz"; tip = "Mac sleeps normally"
        }
        item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        item.button?.imagePosition = .imageLeft
        item.button?.title = closureTitle()
        item.button?.toolTip = "lid-awake: \(tip)"
        item.menu = buildMenu()
    }

    var nowSecs: Int { Int(Date().timeIntervalSince1970) }

    // The closure in progress, if the lid is closed right now.
    var liveClosure: Closure? {
        guard status["lid"] == "closed", let c = history.first, c.end == nil else { return nil }
        return c
    }

    // Text beside the icon: live while closed (visible on an external display),
    // then the total for a few minutes after the lid opens.
    func closureTitle() -> String {
        if let c = liveClosure {
            return status["holding"] == "1" ? " closed \(duration(nowSecs - c.start))" : ""
        }
        guard status["lid"] != "closed", let c = history.first, let end = c.end,
              nowSecs - end < showAfterOpenSecs else { return "" }
        return " closed \(duration(end - c.start))"
    }

    // Lid history > day > closure > the tasks that ran during it.
    func historyMenu() -> NSMenu {
        let menu = NSMenu()
        let done = history.filter { $0.end != nil }
        if done.isEmpty {
            menu.addItem(NSMenuItem(title: "Nothing yet", action: nil, keyEquivalent: ""))
            return menu
        }
        var days: [(name: String, closures: [Closure])] = []
        for c in done {
            let name = dayName(c.start)
            if days.last?.name == name { days[days.count - 1].closures.append(c) } else { days.append((name, [c])) }
        }
        for day in days {
            let total = day.closures.reduce(0) { $0 + ($1.end ?? $1.start) - $1.start }
            let count = day.closures.count == 1 ? "1 closure" : "\(day.closures.count) closures"
            let dayItem = NSMenuItem(title: "\(day.name)  ·  \(count), \(duration(total))", action: nil, keyEquivalent: "")
            let dayMenu = NSMenu()
            for c in day.closures {
                let end = c.end ?? c.start
                let row = NSMenuItem(title: "\(clock(c.start)) → \(clock(end))  ·  closed \(duration(end - c.start)), awake \(duration(c.awake))", action: nil, keyEquivalent: "")
                if !c.tasks.isEmpty {
                    let taskMenu = NSMenu()
                    for t in c.tasks {
                        let result = ["completed": "completed", "stopped": "stopped at the 4h limit", "running": "still working when opened"][t.result] ?? t.result
                        let project = (t.cwd as NSString).lastPathComponent
                        taskMenu.addItem(NSMenuItem(title: "\(project)  ·  \(duration(t.secs))  ·  \(result)", action: nil, keyEquivalent: ""))
                    }
                    row.submenu = taskMenu
                }
                dayMenu.addItem(row)
            }
            dayItem.submenu = dayMenu
            menu.addItem(dayItem)
        }
        return menu
    }

    func buildMenu() -> NSMenu {
        let menu = NSMenu()
        func info(_ text: String) { menu.addItem(NSMenuItem(title: text, action: nil, keyEquivalent: "")) }
        func action(_ text: String, _ sel: Selector) {
            let i = NSMenuItem(title: text, action: sel, keyEquivalent: "")
            i.target = self
            menu.addItem(i)
        }

        if status.isEmpty {
            info("lid-awake is not installed (\(script) missing)")
        } else {
            let working = int("working"), waiting = int("waiting")
            if status["paused"] == "1" {
                info("Paused: Mac sleeps normally until your next prompt")
            } else if status["holding"] == "1" {
                info("Holding Mac awake: \(working) working, \(waiting) waiting")
            } else if working + waiting > 0 {
                info("Not holding (battery at \(status["battery"] ?? "?")%, stops at \(status["min_battery"] ?? "?")%)")
            } else {
                info("Not holding: no Claude session is working")
            }
            if waiting > 0 { info("Waiting on you: sleeps in \(duration(int("wait_left")))") }
            if status["holding"] == "1" && int("idle_left") > 0 { info("Finished: sleeps in \(duration(int("idle_left"))) if the lid is closed") }
            if let c = liveClosure {
                info("Lid closed for \(duration(nowSecs - c.start)): \(duration(int("lid_used"))) of \(duration(int("cap"))) limit used")
            } else if let c = history.first, let end = c.end {
                info("Lid open: last closed \(duration(end - c.start)), awake \(duration(c.awake))")
            } else {
                info("Lid open")
            }
            let power = status["power"] == "ac" ? "on charger" : "on battery"
            info("Battery \(status["battery"] ?? "?")%, \(power)")
            if status["sudo"] != "ok" { info("⚠︎ sudo rule missing: run install.sh") }
            let lidHistory = NSMenuItem(title: "Lid history", action: nil, keyEquivalent: "")
            lidHistory.submenu = historyMenu()
            menu.addItem(lidHistory)

            if let result = status["last_result"] {
                menu.addItem(.separator())
                let ended = Date(timeIntervalSince1970: TimeInterval(int("last_ended")))
                let when = DateFormatter.localizedString(from: ended, dateStyle: .short, timeStyle: .short)
                let label = result == "stopped" ? "Stopped at the 4h limit" : "Completed"
                info("Last lid-closed task: \(label), \(when)")
                info("   \(status["last_cwd"] ?? "")  ·  \(duration(int("last_lid_secs"))) lid closed")
                if status["last_handoff"] != nil { action("Open handoff note", #selector(openHandoff)) }
                action("Resume this session in Terminal", #selector(resume))
            }

            menu.addItem(.separator())
            action("Let Mac sleep now", #selector(sleepNow))
            action("Open log", #selector(openLog))
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit menu bar icon", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        return menu
    }

    @objc func sleepNow() { _ = run(["off"]); refresh() }

    @objc func openLog() {
        if let log = status["log"] { NSWorkspace.shared.open(URL(fileURLWithPath: log)) }
    }

    @objc func openHandoff() {
        if let path = status["last_handoff"] { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
    }

    // Opens Terminal on a small .command file: no Automation permission needed.
    @objc func resume() {
        guard let session = status["last_session"], let cwd = status["last_cwd"] else { return }
        var cmd = "claude --resume '\(session)'"
        if status["last_result"] == "stopped" {
            cmd += " 'You were stopped at the lid-awake 4-hour limit. Read your LID-AWAKE HANDOFF note above, check the current state of the files and any commands it lists before trusting it, then continue with the exact next step.'"
        }
        let file = "\(dir)/resume.command"
        let body = "#!/bin/zsh -l\ncd '\(cwd)' || exit 1\n\(cmd)\n"
        do {
            try body.write(toFile: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file)
            NSWorkspace.shared.open(URL(fileURLWithPath: file))
        } catch {
            NSSound.beep()
        }
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
