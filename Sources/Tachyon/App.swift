import AppKit
@preconcurrency import UserNotifications
import ServiceManagement
import SwiftUI

@main
enum TachyonMain {
    static func main() {
        if SmokeTest.runIfRequested() { return }

        let app = NSApplication.shared
        // Set unconditionally in code, before the run loop: `swift run` must
        // behave exactly like the signed bundle. `LSUIElement` is belt-and-braces.
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let model = UsageModel()
    private var edge: EdgeController?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.app.info("Tachyon launching")

        let edge = EdgeController(model: model)
        self.edge = edge

        edge.onPillRightClick = { [weak self] providerID in
            self?.openSettings(selecting: providerID)
        }
        model.onSlotsChanged = { [weak edge, weak self] in
            edge?.rebuild()
            self?.refreshStatusIcon()
        }
        edge.start()
        model.start()

        installStatusItem()
    }

    func applicationWillTerminate(_ notification: Notification) {
        edge?.stop()
    }

    // MARK: Status item

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.statusImage(percent: nil, darkMenuBar: true)
        // Colored (non-template) icon: adapt to menu-bar theme flips ourselves.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                (NSApp.delegate as? AppDelegate)?.refreshStatusIcon()
            }
        }
        item.button?.toolTip = "Tachyon"
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        refreshStatusIcon()
        installMainMenu()
    }

    /// An accessory app has no visible menu bar of its own, but key
    /// equivalents (⌘, ⌘W ⌘Q) only route through NSApp.mainMenu — install a
    /// minimal invisible one.
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(NSMenuItem(title: "Quit Tachyon", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        fileItem.submenu = fileMenu
        main.addItem(fileItem)
        NSApp.mainMenu = main
    }

    /// The gauge fills with the summary usage across enabled providers.
    func refreshStatusIcon() {
        let percents = model.slots
            .filter { $0.enabled && $0.presence == .ready }
            .compactMap(\.ringPercent)
        let summary = percents.isEmpty ? nil : percents.reduce(0, +) / Double(percents.count)
        let dark = statusItem?.button?.effectiveAppearance.isDarkTheme ?? true
        statusItem?.button?.image = Self.statusImage(percent: summary, darkMenuBar: dark)
        if let summary {
            statusItem?.button?.toolTip = "Tachyon — \(Int(summary.rounded()))% used across enabled tools"
        } else {
            statusItem?.button?.toolTip = "Tachyon"
        }
    }

    /// Monochrome gauge: a thin outline circle that fills like a pie —
    /// clockwise from 12 o'clock — with the summary usage of the enabled
    /// providers. Template image; the menu bar tints it for either theme.
    private static func statusImage(percent: Double?, darkMenuBar: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let outline = rect.insetBy(dx: 2.5, dy: 2.5)

            let neutral: NSColor = darkMenuBar ? .white : .black
            let ring = NSBezierPath(ovalIn: outline)
            ring.lineWidth = 1.5
            neutral.withAlphaComponent(0.9).setStroke()
            ring.stroke()

            if let percent {
                // Pie wedge, inset from the outline so the fill reads as
                // liquid inside the ring rather than touching it.
                let fillRadius = outline.width / 2 - 2
                let fraction = min(100, max(0, percent)) / 100
                let fill = UsageColor.nsBand(percent, darkAppearance: darkMenuBar)
                if fraction >= 0.999 {
                    let disc = NSBezierPath(ovalIn: NSRect(
                        x: center.x - fillRadius, y: center.y - fillRadius,
                        width: fillRadius * 2, height: fillRadius * 2))
                    fill.setFill()
                    disc.fill()
                } else if fraction > 0.01 {
                    let wedge = NSBezierPath()
                    wedge.move(to: center)
                    wedge.appendArc(
                        withCenter: center,
                        radius: fillRadius,
                        startAngle: 90,
                        endAngle: 90 - 360 * fraction,
                        clockwise: true
                    )
                    wedge.close()
                    fill.setFill()
                    wedge.fill()
                }
            } else {
                // No live provider: centered dash inside the empty ring.
                let dash = NSBezierPath()
                dash.move(to: NSPoint(x: center.x - 3, y: center.y))
                dash.line(to: NSPoint(x: center.x + 3, y: center.y))
                dash.lineWidth = 2
                dash.lineCapStyle = .round
                neutral.withAlphaComponent(0.6).setStroke()
                dash.stroke()
            }
            return true
        }
        // Colored, so not a template — theme adaptation handled in the drawing.
        image.isTemplate = false
        return image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // Every supported harness, in registry order — active ones are
        // toggleable, inactive ones sit grayed with the reason why.
        for slot in model.slots {
            let item: NSMenuItem
            switch slot.presence {
            case .notInstalled:
                item = NSMenuItem(title: "\(slot.shortName) — not installed", action: nil, keyEquivalent: "")
                item.isEnabled = false
            case .notSignedIn(let guidance):
                item = NSMenuItem(title: "\(slot.shortName) — \(guidance)", action: nil, keyEquivalent: "")
                item.isEnabled = false
            case .ready:
                item = NSMenuItem(
                    title: menuTitle(for: slot),
                    action: #selector(toggleProvider(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = slot.id
                item.state = slot.enabled ? .on : .off
            }
            item.image = Self.menuGlyph(slot.glyph)
            if let about = slot.about { item.toolTip = about }
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let hint = NSMenuItem(title: "Add Your Harness…", action: #selector(copyHarnessPrompt), keyEquivalent: "")
        hint.target = self
        hint.toolTip = "Copies a prompt to paste into your coding agent; it implements the provider itself"
        menu.addItem(hint)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())

        let refresh = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        menu.addItem(displayMenuItem())
        menu.addItem(launchAtLoginItem())

        menu.addItem(.separator())
        let about = NSMenuItem(title: "About Tachyon", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Tachyon", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    /// 16pt template rendering of a provider mark for menu rows. Cached —
    /// menus rebuild on every open.
    private static var menuGlyphCache: [ProviderGlyph: NSImage] = [:]

    private static func menuGlyph(_ glyph: ProviderGlyph) -> NSImage {
        if let cached = menuGlyphCache[glyph] { return cached }
        let side: CGFloat = 16
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let path = GlyphShape(glyph: glyph)
                .path(in: rect.insetBy(dx: 1, dy: 1))
            context.addPath(path.cgPath)
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath(using: .evenOdd)
            return true
        }
        image.isTemplate = true
        menuGlyphCache[glyph] = image
        return image
    }

    private func menuTitle(for slot: ProviderSlot) -> String {
        var title = slot.shortName
        if slot.isExperimental { title += " (experimental)" }
        if let percent = slot.ringPercent {
            title += " — \(Int(percent.rounded()))%"
            if slot.state.isStale { title += " (stale)" }
        } else if let spend = slot.ringSpend {
            title += " — \(UsageWindow.formatSpend(spend))"
            if slot.state.isStale { title += " (stale)" }
        } else if let count = slot.ringCount {
            title += " — \(count)"
        } else if let guidance = slot.state.authGuidance {
            title += " — \(guidance)"
        }
        return title
    }

    // MARK: Display picker

    private func displayMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Display", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        let automatic = NSMenuItem(title: "Automatic (Main)", action: #selector(selectDisplay(_:)), keyEquivalent: "")
        automatic.target = self
        automatic.representedObject = NSNumber(value: 0)
        automatic.state = Settings.preferredDisplayID == nil ? .on : .off
        submenu.addItem(automatic)

        if NSScreen.screens.count > 1 {
            submenu.addItem(.separator())
            for (index, screen) in NSScreen.screens.enumerated() {
                guard let id = screen.displayID else { continue }
                let name = screen.localizedName.isEmpty ? "Display \(index + 1)" : screen.localizedName
                let item = NSMenuItem(title: name, action: #selector(selectDisplay(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = NSNumber(value: id)
                item.state = Settings.preferredDisplayID == id ? .on : .off
                submenu.addItem(item)
            }
        }

        parent.submenu = submenu
        return parent
    }

    // MARK: Launch at login

    /// `SMAppService` registers a *bundle*, so the toggle is meaningless when
    /// running the bare SwiftPM binary. Registrations made from a build
    /// directory also die on the next rebuild — hence the `~/Applications`
    /// guidance in the README.
    private func launchAtLoginItem() -> NSMenuItem {
        let service = SMAppService.mainApp
        let bundled = Self.isRunningFromBundle

        guard bundled else {
            let item = NSMenuItem(title: "Launch at Login (install to ~/Applications)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.toolTip = "Run build.sh and copy Tachyon.app to ~/Applications to enable this."
            return item
        }

        let status = service.status
        var title = "Launch at Login"
        switch status {
        case .requiresApproval:
            title += " — approve in System Settings"
        case .notFound:
            title += " — not registered"
        default:
            break
        }

        let item = NSMenuItem(title: title, action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        item.target = self
        item.state = status == .enabled ? .on : .off
        return item
    }

    private static var isRunningFromBundle: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")
    }

    // MARK: Actions

    @objc private func toggleProvider(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let slot = model.slot(id: id) else { return }
        model.setEnabled(!slot.enabled, for: id)
    }

    @objc private func refreshNow() {
        model.refreshAll()
    }

    @objc private func selectDisplay(_ sender: NSMenuItem) {
        let raw = (sender.representedObject as? NSNumber)?.uint32Value ?? 0
        Settings.preferredDisplayID = raw == 0 ? nil : CGDirectDisplayID(raw)
        edge?.rebuild()
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            Log.app.error("Launch at login toggle failed: \(error.localizedDescription, privacy: .public)")
            let alert = NSAlert()
            alert.messageText = "Could not change Launch at Login"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    /// Same prompt as README/website: paste into a coding agent and the
    /// provider adds itself.
    @objc private func copyHarnessPrompt() {
        let prompt = """
        Add support for {YOUR HARNESS} to Tachyon, the macOS usage-rings app.

        1. git clone https://github.com/Gonzih/tachyon and read CONTRIBUTING.md — it defines the UsageProvider protocol and the acceptance checklist.
        2. Investigate how {YOUR HARNESS} stores credentials locally and where its usage/rate-limit data lives (endpoint, log files, or CLI output).
        3. Implement Sources/Tachyon/Providers/{Name}Provider.swift on the pattern of GrokProvider.swift, add one line to ProviderRegistry, add a glyph.
        4. Verify with `swift run Tachyon --smoke` — your provider must show real numbers, or degrade cleanly to "not signed in".
        5. Open a PR titled "provider: {name}".

        NEVER LEAK CREDENTIALS. No tokens, keys, cookies, session ids, account ids, or emails — not in code, comments, test fixtures, logs, commit history, or the PR description. Credentials are read at runtime from the user's machine and go into request headers only; log lines must redact them. If smoke-test output contains identifying data, scrub it before pasting anywhere.
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)
        notify(title: "Prompt copied", body: "Paste it into your agent — it adds the provider itself.")
    }

    /// First notification use also requests authorization — the early step
    /// toward richer notifications (limit alerts, resets) later.
    private func notify(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(
                identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    @objc func showSettings() {
        SettingsWindow.show(model: model)
    }

    func openSettings(selecting providerID: String?) {
        SettingsWindow.show(model: model, selecting: providerID)
    }

    @objc private func showAbout() {
        AboutWindow.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
