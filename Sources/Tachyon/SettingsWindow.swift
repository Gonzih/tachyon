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

    fileprivate static func owns(_ candidate: Any?) -> Bool {
        guard let candidate = candidate as? NSWindow, let window else { return false }
        return candidate === window
    }

    static func show(model: UsageModel, selecting providerID: String? = nil) {
        if let providerID {
            selection.id = model.slots.contains(where: {
                $0.id == providerID && $0.presence != .notInstalled
            }) ? providerID : "general"
        }
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
                    SidebarRow(title: slot.nameWithSource, glyph: slot.glyph, selected: selection.id == slot.id)
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
        .onAppear(perform: validateSelection)
        .onChange(of: visibleSlots.map(\.id)) { _, _ in validateSelection() }
    }

    private func validateSelection() {
        guard selection.id != "general",
              visibleSlots.contains(where: { $0.id == selection.id }) == false
        else { return }
        selection.id = "general"
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
            Text(title)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

struct LaunchAtLoginControlState: Equatable {
    enum Request: Equatable {
        case register
        case unregister
    }

    private(set) var isEnabled: Bool
    private(set) var requiresApproval: Bool

    init(isEnabled: Bool = false, requiresApproval: Bool = false) {
        self.isEnabled = isEnabled
        self.requiresApproval = requiresApproval
    }

    /// Authoritative service updates never emit a user request. Keeping this
    /// separate from the Toggle binding prevents a window-activation refresh
    /// from registering or unregistering the app again.
    mutating func synchronize(isEnabled: Bool, requiresApproval: Bool) {
        self.isEnabled = isEnabled
        self.requiresApproval = requiresApproval
    }

    func request(for wanted: Bool) -> Request? {
        guard wanted != isEnabled else { return nil }
        return wanted ? .register : .unregister
    }
}

private struct GeneralPane: View {
    @State private var controlState = LaunchAtLoginControlState()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("General").font(.system(size: 16, weight: .semibold))

            Toggle("Launch at Login", isOn: Binding(
                get: { controlState.isEnabled },
                set: { wanted in requestLaunchAtLogin(wanted) }
            ))
                .disabled(Bundle.main.bundlePath.hasSuffix(".app") == false)

            if controlState.requiresApproval {
                Text("Waiting for approval in System Settings → Login Items.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Text("Display and quick provider toggles live in the menu-bar dropdown.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
            Spacer()
        }
        .onAppear { synchronizeLaunchAtLogin() }
        // The Settings NSWindow is retained after close, so SwiftUI may not run
        // onAppear again. Re-read SMAppService whenever a window becomes key;
        // synchronization is side-effect-free and therefore safe to repeat.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            guard SettingsWindow.owns(notification.object) else { return }
            synchronizeLaunchAtLogin()
        }
    }

    private func requestLaunchAtLogin(_ wanted: Bool) {
        guard let request = controlState.request(for: wanted) else { return }
        do {
            switch request {
            case .register:
                try SMAppService.mainApp.register()
            case .unregister:
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.app.error("Launch at login toggle failed")
        }
        synchronizeLaunchAtLogin()
    }

    private func synchronizeLaunchAtLogin() {
        let status = SMAppService.mainApp.status
        controlState.synchronize(
            isEnabled: status == .enabled,
            requiresApproval: status == .requiresApproval
        )
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
                    Text(slot.nameWithSource).font(.system(size: 16, weight: .semibold))
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
        ProviderSettingsStatusLine.text(
            enabled: slot.enabled,
            awaitingFirstSnapshot: slot.awaitingFirstSnapshot,
            presence: slot.presence,
            state: slot.state,
            lastPolled: slot.lastPolled,
            displaysStale: slot.displaysStale()
        )
    }
}

enum ProviderSettingsStatusLine {
    static func text(
        enabled: Bool,
        awaitingFirstSnapshot: Bool,
        presence: ProviderPresence,
        state: ProviderState,
        lastPolled: Date?,
        displaysStale: Bool? = nil
    ) -> String {
        guard enabled else { return "Disabled" }
        if awaitingFirstSnapshot { return "Checking…" }

        switch presence {
        case .notInstalled:
            return "Not installed"
        case .notSignedIn(let guidance):
            return guidance
        case .ready:
            var parts: [String] = []
            if displaysStale ?? state.isStale { parts.append("stale") }
            if let lastPolled {
                parts.append("polled \(ResetFormat.relative(lastPolled))")
            }
            if let detail = state.snapshot?.detail { parts.append(detail) }
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

struct MoneyFieldState: Equatable {
    enum Submission: Equatable {
        case noChange
        case save(Double?)
    }

    var input = ""
    private(set) var isDirty = false

    mutating func synchronize(value: Double?) {
        input = Self.format(value)
        isDirty = false
    }

    mutating func updateInput(_ value: String) {
        input = value
        isDirty = true
    }

    func submission() -> Submission {
        guard isDirty else { return .noChange }
        let cleaned = input.replacingOccurrences(of: "$", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = Double(cleaned)
        let value = parsed.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        return .save(value)
    }

    private static func format(_ value: Double?) -> String {
        guard let value, value.isFinite, value > 0 else { return "" }
        if value < Double(Int.max), value.truncatingRemainder(dividingBy: 1) == 0 {
            return "$\(Int(value))"
        }
        return String(format: "$%.2f", value)
    }
}

private struct MoneyField: View {
    let setting: ProviderSetting
    let providerID: String
    let defaultValue: Double?
    let onChange: () -> Void

    @State private var fieldState = MoneyFieldState()

    var body: some View {
        HStack(spacing: 6) {
            TextField("none", text: Binding(
                get: { fieldState.input },
                set: { fieldState.updateInput($0) }
            ))
                .frame(width: 84)
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder)
                .onSubmit { commit() }

            Button("Save") { commit() }
                .controlSize(.small)
                .disabled(!fieldState.isDirty)
        }
        .onAppear { synchronizeMoneyState(useDefault: true) }
    }

    /// Empty or junk clears the setting (removes the key — never writes 0).
    private func commit() {
        guard case .save(let value) = fieldState.submission() else { return }
        Settings.setMoneySetting(value, suffix: setting.key, provider: providerID)
        synchronizeMoneyState(useDefault: false)
        onChange()
    }

    private func synchronizeMoneyState(useDefault: Bool) {
        let stored = Settings.moneySetting(setting.key, provider: providerID)
        fieldState.synchronize(value: stored ?? (useDefault ? defaultValue : nil))
    }
}

struct SecretFieldState: Equatable {
    enum Action: Equatable {
        case replace(String)
        case clear
    }

    enum Submission: Equatable {
        case noChange
        case invalidPresentationMask
        case action(Action)
    }

    static let existingSecretMask = "••••••••"

    var input = ""
    private(set) var hasExistingSecret = false

    mutating func synchronize(hasExistingSecret: Bool) {
        self.hasExistingSecret = hasExistingSecret
        input = ""
    }

    func submission() -> Submission {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .noChange }
        guard !trimmed.contains(Self.existingSecretMask) else {
            return .invalidPresentationMask
        }
        return .action(.replace(trimmed))
    }

    var clearAction: Action? {
        hasExistingSecret ? .clear : nil
    }

    var replacementButtonTitle: String {
        hasExistingSecret ? "Replace" : "Save"
    }

    var canSubmitReplacement: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    mutating func discardInput() {
        input = ""
    }

    mutating func didPersist(_ action: Action) {
        switch action {
        case .replace:
            hasExistingSecret = true
        case .clear:
            hasExistingSecret = false
        }
        discardInput()
    }
}

private struct SecretField: View {
    let setting: ProviderSetting
    let providerID: String
    let placeholder: String
    let onChange: () -> Void

    @State private var fieldState = SecretFieldState()
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            SecureField(
                fieldState.hasExistingSecret
                    ? SecretFieldState.existingSecretMask
                    : placeholder,
                text: $fieldState.input
            )
            .textFieldStyle(.roundedBorder)
            .onSubmit { commitReplacement() }
            .help(fieldState.hasExistingSecret
                ? "Enter a new value to replace the saved secret."
                : placeholder)

            HStack(spacing: 6) {
                if fieldState.hasExistingSecret {
                    Button("Clear", role: .destructive) { clear() }
                        .controlSize(.small)
                }
                Spacer()
                Button(fieldState.replacementButtonTitle) { commitReplacement() }
                    .controlSize(.small)
                    .disabled(!fieldState.canSubmitReplacement)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: 170)
        .onAppear { synchronizeSecretState() }
        .onDisappear { discardPlaintextInput() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { notification in
            guard SettingsWindow.owns(notification.object) else { return }
            discardPlaintextInput()
        }
    }

    private func synchronizeSecretState() {
        fieldState.synchronize(
            hasExistingSecret: Settings.secretSetting(setting.key, provider: providerID) != nil
        )
        errorMessage = nil
    }

    private func commitReplacement() {
        switch fieldState.submission() {
        case .noChange:
            return
        case .invalidPresentationMask:
            fieldState.input = ""
            errorMessage = "Enter the new secret to replace the saved value."
        case .action(let action):
            persist(action)
        }
    }

    private func clear() {
        guard let action = fieldState.clearAction else { return }
        persist(action)
    }

    private func discardPlaintextInput() {
        fieldState.discardInput()
        errorMessage = nil
    }

    private func persist(_ action: SecretFieldState.Action) {
        let value: String?
        switch action {
        case .replace(let replacement):
            value = replacement
        case .clear:
            value = nil
        }

        switch Settings.setSecretSetting(value, suffix: setting.key, provider: providerID) {
        case .success:
            errorMessage = nil
            fieldState.didPersist(action)
            onChange()
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }
}
