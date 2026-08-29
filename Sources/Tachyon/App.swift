import AppKit
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

        edge.onPillRightClick = { [weak self] event, view in
            guard let self else { return }
            // Same menu as the status item — the status item can be swallowed
            // by menu-bar overflow on notched Macs, so the pill must never be
            // stranded without its controls.
            let menu = NSMenu()
            menu.delegate = self
            NSMenu.popUpContextMenu(menu, with: event, for: view)
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
            menu.addItem(item)
        }

        let recentlyCopied = promptCopiedAt.map { Date().timeIntervalSince($0) < 60 } ?? false
        let hint = NSMenuItem(
            title: recentlyCopied ? "✓ Prompt Copied — Paste Into Your Agent" : "Add Your Harness — Copy Agent Prompt",
            action: #selector(copyHarnessPrompt),
            keyEquivalent: ""
        )
        hint.target = self
        hint.toolTip = "Copies a prompt to paste into your coding agent; it implements the provider itself"
        menu.addItem(hint)

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
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)
        promptCopiedAt = Date()

        // Visible confirmation even though the menu just closed: the status
        // gauge flashes a green checkmark, then returns to the usage dial.
        statusItem?.button?.image = Self.checkmarkImage()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            self?.refreshStatusIcon()
        }
    }

    private var promptCopiedAt: Date? {
        get { UserDefaults.standard.object(forKey: "harnessPromptCopiedAt") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "harnessPromptCopiedAt") }
    }

    private static func checkmarkImage() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 2.5, dy: 2.5))
            ring.lineWidth = 1.5
            NSColor.systemGreen.setStroke()
            ring.stroke()
            let check = NSBezierPath()
            check.move(to: NSPoint(x: 5.5, y: 9))
            check.line(to: NSPoint(x: 8, y: 6.5))
            check.line(to: NSPoint(x: 12.5, y: 11.5))
            check.lineWidth = 2
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            NSColor.systemGreen.setStroke()
            check.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }

    @objc private func showAbout() {
        AboutWindow.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
