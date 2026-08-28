import AppKit
import SwiftUI

/// "About Tachyon" — a small standard window in the app's visual language:
/// the gauge mark, the name, the humans, the borrowed art.
@MainActor
enum AboutWindow {
    private static var window: NSWindow?

    static func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: AboutView())
        let panel = NSWindow(contentViewController: hosting)
        panel.styleMask = [.titled, .closable]
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isReleasedWhenClosed = false
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.center()
        panel.title = "About Tachyon"
        window = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct AboutView: View {
    @Environment(\.colorScheme) private var colorScheme

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    var body: some View {
        VStack(spacing: 0) {
            appIcon
                .padding(.bottom, 14)

            Text("Tachyon")
                .font(.system(size: 24, weight: .bold, design: .rounded))

            Text("Version \(version)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.top, 3)

            Divider()
                .frame(width: 168)
                .padding(.vertical, 16)

            Text("Made by Maksim Soltan")
                .font(.system(size: 12, weight: .medium))

            HStack(spacing: 6) {
                Link("code@maksim.sh", destination: URL(string: "mailto:code@maksim.sh")!)
                dot
                Link("maksim.sh", destination: URL(string: "https://maksim.sh")!)
                dot
                Link("tachyon.maksim.sh", destination: URL(string: "https://tachyon.maksim.sh")!)
            }
            .font(.system(size: 11))
            .padding(.top, 5)

            VStack(spacing: 3) {
                Link("Wild Honey on the Porch, LLC", destination: URL(string: "https://studio.wildhoneyontheporch.com/")!)
                    .foregroundStyle(.secondary)
                Link("Design concept by @hivinz_", destination: URL(string: "https://x.com/hivinz_/status/2092996055248126353")!)
                    .foregroundStyle(.secondary)
                Text("Provider marks: simple-icons (CC0),\nWikimedia Commons, lobehub icons (MIT)")
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
            .font(.system(size: 10))
            .padding(.top, 16)
        }
        .padding(.horizontal, 32)
        .padding(.top, 20)
        .padding(.bottom, 22)
        .frame(width: 300)
    }

    private var dot: some View {
        Text("·").font(.system(size: 11)).foregroundStyle(.tertiary)
    }

    /// The real app icon — same rounded-square gauge that lives in Finder.
    private var appIcon: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .frame(width: 88, height: 88)
            .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
    }
}

