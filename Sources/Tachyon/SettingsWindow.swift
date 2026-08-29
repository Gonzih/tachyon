import AppKit
import SwiftUI
import ServiceManagement

/// The Settings window: General + one pane per detected provider. Every pane
/// doubles as a diagnostic view (presence, last poll, plan) and carries the
/// provider's Enabled toggle plus its declared settings, rendered generically.
@MainActor
@Observable
final class SettingsSelection {
    var id: String = "general"
}

@MainActor
enum SettingsWindow {
    private static var window: NSWindow?
    private static let selection = SettingsSelection()

    static func show(model: UsageModel, selecting providerID: String? = nil) {
        if let providerID { selection.id = providerID }
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: SettingsRoot(model: model, selection: selection))
        let panel = NSWindow(contentViewController: hosting)
        panel.styleMask = [.titled, .closable]
        panel.title = "Tachyon Settings"
        panel.isReleasedWhenClosed = false
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.center()
        window = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Root: sidebar + pane

private struct SettingsRoot: View {
    let model: UsageModel
    @Bindable var selection: SettingsSelection

    /// Detected = anything installed, signed in or not — the pane is the
    /// diagnostic surface, so signed-out providers belong here too.
    private var visibleSlots: [ProviderSlot] {
        model.slots.filter { $0.presence != .notInstalled }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                SidebarRow(title: "General", glyph: nil, selected: selection.id == "general")
                    .onTapGesture { selection.id = "general" }
                Divider().padding(.vertical, 6)
                ForEach(Array(visibleSlots.enumerated()), id: \.element.id) { index, slot in
                    if index > 0, visibleSlots[index - 1].category != slot.category {
                        Divider().padding(.vertical, 4)
                    }
                    SidebarRow(title: slot.shortName, glyph: slot.glyph, selected: selection.id == slot.id)
                        .onTapGesture { selection.id = slot.id }
                }
                Spacer()
            }
            .padding(10)
            .frame(width: 168)
            .frame(maxHeight: .infinity)
            // Material gives the sidebar a distinct elevation in BOTH themes —
            // a flat quaternary wash disappears against dark window chrome.
            .background(.ultraThinMaterial)

            Divider()

            Group {
                if selection.id == "general" {
                    GeneralPane()
                } else if let slot = model.slot(id: selection.id) {
                    ProviderPane(model: model, slot: slot)
                } else {
                    GeneralPane()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(22)
        }
        .frame(width: 560, height: 360)
    }
}

private struct SidebarRow: View {
    let title: String
    let glyph: ProviderGlyph?
    let selected: Bool

    var body: some View {
        HStack(spacing: 8) {
            if let glyph {
                GlyphView(glyph: glyph, size: 14, color: .primary)
            } else {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 12))
                    .frame(width: 14)
            }
            Text(title).font(.system(size: 13))
            Spacer()
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(selected ? Color.accentColor.opacity(0.18) : .clear)
        )
        .contentShape(Rectangle())
    }
}

// MARK: - General

private struct GeneralPane: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("General").font(.system(size: 16, weight: .semibold))

            Toggle("Launch at Login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, wanted in
                    do {
                        if wanted { try SMAppService.mainApp.register() }
                        else { try SMAppService.mainApp.unregister() }
                    } catch {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
                .disabled(Bundle.main.bundlePath.hasSuffix(".app") == false)

            if SMAppService.mainApp.status == .requiresApproval {
                Text("Waiting for approval in System Settings → Login Items.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Text("Display and quick provider toggles live in the menu-bar dropdown.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
            Spacer()
        }
    }
}

// MARK: - Provider pane

private struct ProviderPane: View {
    let model: UsageModel
    let slot: ProviderSlot

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 11) {
                GlyphView(glyph: slot.glyph, size: 20, color: .primary)
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: 9).fill(.quaternary.opacity(0.5)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(slot.shortName).font(.system(size: 16, weight: .semibold))
                    Text(statusLine).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { slot.enabled },
                    set: { model.setEnabled($0, for: slot.id) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            if let about = slot.about {
                Text(about)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !slot.providerSettings.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(slot.providerSettings.enumerated()), id: \.element.id) { index, setting in
                        if index > 0 { Divider().padding(.leading, 14) }
                        SettingField(setting: setting, providerID: slot.id) {
                            model.refresh(id: slot.id)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.quaternary.opacity(0.55))
                )
                .padding(.top, 6)
            }
            Spacer()
        }
    }

    private var statusLine: String {
        switch slot.presence {
        case .notInstalled: return "Not installed"
        case .notSignedIn(let guidance): return guidance
        case .ready:
            var parts: [String] = []
            if let polled = slot.lastPolled {
                parts.append("polled \(ResetFormat.relative(polled))")
            }
            if let detail = slot.snapshot?.detail { parts.append(detail) }
            return parts.isEmpty ? "Ready" : parts.joined(separator: " · ")
        }
    }
}

// MARK: - Generic setting renderers

private struct SettingField: View {
    let setting: ProviderSetting
    let providerID: String
    let onChange: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(setting.title).font(.system(size: 13, weight: .medium))
                if let help = setting.help {
                    Text(help)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 16)
            control
        }
    }

    @ViewBuilder private var control: some View {
        switch setting.kind {
        case .secret(let placeholder):
            SecretField(setting: setting, providerID: providerID,
                        placeholder: placeholder, onChange: onChange)
        case .money(let defaultValue):
            MoneyField(setting: setting, providerID: providerID,
                       defaultValue: defaultValue, onChange: onChange)
        case .toggle(let defaultValue):
            Toggle("", isOn: Binding(
                get: { Settings.defaults.object(forKey: "provider.\(providerID).\(setting.key)") as? Bool ?? defaultValue },
                set: { Settings.defaults.set($0, forKey: "provider.\(providerID).\(setting.key)"); onChange() }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
        case .choice(let options, let defaultValue):
            Picker("", selection: Binding(
                get: { Settings.defaults.string(forKey: "provider.\(providerID).\(setting.key)") ?? defaultValue },
                set: { Settings.defaults.set($0, forKey: "provider.\(providerID).\(setting.key)"); onChange() }
            )) {
                ForEach(options, id: \.self) { Text($0) }
            }
            .labelsHidden()
            .frame(width: 140)
        }
    }
}

private struct MoneyField: View {
    let setting: ProviderSetting
    let providerID: String
    let defaultValue: Double?
    let onChange: () -> Void

    @State private var text: String = ""

    var body: some View {
        TextField("none", text: $text)
            .frame(width: 84)
            .multilineTextAlignment(.trailing)
            .textFieldStyle(.roundedBorder)
            .onSubmit(commit)
            .onAppear {
                let stored = Settings.moneySetting(setting.key, provider: providerID) ?? defaultValue
                text = stored.map { $0.truncatingRemainder(dividingBy: 1) == 0 ? "$\(Int($0))" : String(format: "$%.2f", $0) } ?? ""
            }
    }

    /// Empty or junk clears the setting (removes the key — never writes 0).
    private func commit() {
        let cleaned = text.replacingOccurrences(of: "$", with: "")
            .trimmingCharacters(in: .whitespaces)
        let value = Double(cleaned)
        Settings.setMoneySetting(value, suffix: setting.key, provider: providerID)
        let stored = Settings.moneySetting(setting.key, provider: providerID)
        text = stored.map { $0.truncatingRemainder(dividingBy: 1) == 0 ? "$\(Int($0))" : String(format: "$%.2f", $0) } ?? ""
        onChange()
    }
}

private struct SecretField: View {
    let setting: ProviderSetting
    let providerID: String
    let placeholder: String
    let onChange: () -> Void

    @State private var text: String = ""

    var body: some View {
        SecureField(placeholder, text: $text)
            .frame(width: 170)
            .textFieldStyle(.roundedBorder)
            .onSubmit(commit)
            .onAppear {
                // Show a mask when a secret exists — never the secret itself.
                text = Settings.secretSetting(setting.key, provider: providerID) == nil ? "" : "••••••••"
            }
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed != "••••••••" else { return }   // untouched mask
        Settings.setSecretSetting(trimmed.isEmpty ? nil : trimmed, suffix: setting.key, provider: providerID)
        text = trimmed.isEmpty ? "" : "••••••••"
        onChange()
    }
}
