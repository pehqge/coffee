import AppKit

// Coffee — menu bar toggle for pmset disablesleep (lid-closed / clamshell run).
// Icon: coffee cup. Active = full white + steam. Inactive = translucent, no steam.
// Left-click toggles. Right-click shows menu (status + Setup + Quit).
// State is read live from `pmset -g` so external changes are reflected too.
//
// Self-bootstrapping: on launch it (1) re-creates its LaunchAgent if missing so
// autostart survives a reinstall, and (2) if the passwordless sudoers rule is
// absent, copies the install command to the clipboard and tells Pedro what to do.

let kLabel = "com.pedro.coffeelid"

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var active = false

    func applicationDidFinishLaunching(_ note: Notification) {
        ensureLaunchAgent()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        refresh()
        if !hasPermission() {
            copyInstallCommand()
            showSetupAlert(autoCopied: true)
        }
        // Poll for external changes. 10s with tolerance keeps CPU/wakeups negligible.
        let t = Timer(timeInterval: 10.0, repeats: true) { [weak self] _ in self?.refresh() }
        t.tolerance = 3.0
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: - Click / menu

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            toggle()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        let status = NSMenuItem(
            title: active ? "Lid-closed run: ON" : "Lid-closed run: OFF",
            action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        let toggleItem = NSMenuItem(
            title: active ? "Disable" : "Enable",
            action: #selector(toggleFromMenu), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)
        let setup = NSMenuItem(
            title: "Setup permission…", action: #selector(setupFromMenu), keyEquivalent: "")
        setup.target = self
        menu.addItem(setup)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil // detach so left-click toggles next time
    }

    @objc private func toggleFromMenu() { toggle() }
    @objc private func setupFromMenu() { copyInstallCommand(); showSetupAlert(autoCopied: true) }
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: - pmset

    private func toggle() {
        let target = active ? "0" : "1"
        if runSudoPmset(target) != 0 {
            copyInstallCommand()
            showSetupAlert(autoCopied: true)
        }
        refresh()
    }

    /// Runs `sudo -n pmset -a disablesleep <value>`. Returns process exit status.
    @discardableResult
    private func runSudoPmset(_ value: String) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", "/usr/bin/pmset", "-a", "disablesleep", value]
        p.standardError = Pipe()
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus }
        catch { return -1 }
    }

    /// Tests the NOPASSWD rule without changing state: re-applies the current value.
    private func hasPermission() -> Bool {
        return runSudoPmset(active ? "1" : "0") == 0
    }

    private func readState() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-g"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return active }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let s = String(data: data, encoding: .utf8) else { return active }
        for line in s.split(separator: "\n") where line.contains("SleepDisabled") {
            let last = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).last
            return last == "1"
        }
        return false // line absent => disablesleep off
    }

    private func refresh() {
        active = readState()
        statusItem.button?.image = Self.cupImage(active: active)
        statusItem.button?.toolTip = active
            ? "Lid-closed run: ON (click to disable)"
            : "Lid-closed run: OFF (click to enable)"
    }

    // MARK: - Setup (sudoers) helper

    private var installCommand: String {
        let user = NSUserName()
        let r0 = "\(user) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0"
        let r1 = "\(user) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1"
        return "printf '\(r0)\\n\(r1)\\n' | sudo tee /etc/sudoers.d/coffee-lid >/dev/null"
            + " && sudo chmod 440 /etc/sudoers.d/coffee-lid"
            + " && sudo visudo -cf /etc/sudoers.d/coffee-lid && echo INSTALLED_OK"
    }

    private func copyInstallCommand() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(installCommand, forType: .string)
    }

    private func showSetupAlert(autoCopied: Bool) {
        let a = NSAlert()
        a.messageText = "One-time setup needed"
        a.informativeText = """
            The toggle needs a passwordless sudo rule for pmset.

            The install command was COPIED to your clipboard. Open Terminal, \
            paste (Cmd+V), press Return, and type your Mac password once.

            You only do this once per machine.
            """
        a.alertStyle = .informational
        a.addButton(withTitle: "Open Terminal")
        a.addButton(withTitle: "Copy command again")
        a.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        let r = a.runModal()
        switch r {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
        case .alertSecondButtonReturn:
            copyInstallCommand()
        default:
            break
        }
    }

    // MARK: - LaunchAgent self-install

    private func ensureLaunchAgent() {
        let fm = FileManager.default
        let dir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
        let plist = dir.appendingPathComponent("\(kLabel).plist")
        guard !fm.fileExists(atPath: plist.path) else { return }
        let exe = Bundle.main.executableURL?.path
            ?? (CommandLine.arguments.first ?? "")
        let content = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>\(kLabel)</string>
                <key>ProgramArguments</key>
                <array>
                    <string>\(exe)</string>
                </array>
                <key>RunAtLoad</key>
                <true/>
                <key>KeepAlive</key>
                <false/>
                <key>ProcessType</key>
                <string>Background</string>
            </dict>
            </plist>
            """
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? content.write(to: plist, atomically: true, encoding: .utf8)
    }

    // MARK: - Icon

    static func cupImage(active: Bool) -> NSImage {
        let size = NSSize(width: 20, height: 18)
        let img = NSImage(size: size)
        img.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high

        let cupAlpha: CGFloat = active ? 1.0 : 0.30
        var glyphTop: CGFloat = 12

        let conf = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        if let sym = NSImage(systemSymbolName: "cup.and.saucer.fill",
                             accessibilityDescription: nil)?
            .withSymbolConfiguration(conf) {
            let sw = sym.size.width
            let sh = sym.size.height
            let rect = NSRect(x: (size.width - sw) / 2, y: 0, width: sw, height: sh)
            sym.draw(in: rect, from: .zero, operation: .sourceOver, fraction: cupAlpha)
            glyphTop = sh
        }

        if active {
            NSColor.black.withAlphaComponent(0.95).setStroke()
            let cx = size.width / 2
            for dx in [-3.0, 0.0, 3.0] as [CGFloat] {
                let x = cx + dx
                let y0 = min(glyphTop - 1, size.height - 5)
                let path = NSBezierPath()
                path.lineWidth = 1.0
                path.lineCapStyle = .round
                path.move(to: NSPoint(x: x, y: y0))
                path.curve(to: NSPoint(x: x, y: y0 + 4),
                           controlPoint1: NSPoint(x: x - 2, y: y0 + 1.3),
                           controlPoint2: NSPoint(x: x + 2, y: y0 + 2.7))
                path.stroke()
            }
        }

        img.unlockFocus()
        img.isTemplate = true // system tints to menu bar color; alpha preserved
        return img
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
