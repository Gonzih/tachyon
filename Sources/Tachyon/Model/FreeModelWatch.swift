import Foundation

/// Watches OpenRouter's public model catalog for models that cost $0 to run.
///
/// This is deliberately NOT a `UsageProvider`: `/api/v1/models` carries no
/// quota, spend, or request count, so there is nothing honest to put on a
/// ring. It is an app-level catalog watch with the same shape as
/// `BrewUpdater` — take a reading, diff it against the last one, notify — and
/// it is declared through the OpenRouter provider's settings so the toggle
/// renders in the existing generic Settings field with no bespoke UI.
///
/// The endpoint needs no credential, so the watch works before an API key is
/// entered. The stored snapshot is a diffing baseline, not account data.
struct FreeModelWatch: Sendable {
    /// Polling the full catalog every five minutes costs ~23 MB/day on the
    /// wire for a signal that changes a few times a month. Fifteen minutes
    /// still catches a launch within a coffee, at a seventh of the traffic.
    static let interval: TimeInterval = 15 * 60

    /// One catalog entry, trimmed to what a notification can honestly show.
    struct Model: Sendable, Equatable, Codable, Identifiable {
        let id: String
        let name: String
        let contextLength: Int?
        let created: Date?
        let inputModalities: [String]
        let outputModalities: [String]
    }

    /// The diff Tachyon reports. Every case means "a model is now $0 that was
    /// not $0 before" — Tachyon never claims a model left the catalog or that
    /// it will stay free.
    enum Change: Sendable, Equatable {
        /// An id Tachyon had never seen, at $0.
        case newFree(Model)
        /// A model Tachyon had already seen at a nonzero price, now $0.
        case becameFree(Model)
        /// A `:free` id appeared for a base model already in the catalog.
        case freeVariantAdded(Model)

        var model: Model {
            switch self {
            case .newFree(let model),
                 .becameFree(let model),
                 .freeVariantAdded(let model):
                return model
            }
        }
    }

    /// The previous and current catalog. `free` is the full record because a
    /// notification needs the name and context length; `paid` is ids only.
    struct Snapshot: Sendable, Equatable, Codable {
        var free: [String: Model] = [:]
        var paid: Set<String> = []
    }

    struct Message: Sendable, Equatable {
        let title: String
        let body: String
    }

    private static let modelsURL = URL(string: "https://openrouter.ai/api/v1/models")!
    private static let snapshotKey = "alerts.freeModels.snapshot"

    // MARK: - Settings gate

    /// The watch is on unless the user turns it off. It is deliberately not
    /// gated on the OpenRouter provider toggle: disabling the ring says "don't
    /// meter my credits", not "don't tell me about free models".
    static func isEnabled(defaults: UserDefaults = Settings.defaults) -> Bool {
        Settings.boolSetting(
            OpenRouterProvider.freeModelAlertsKey,
            provider: OpenRouterProvider.providerID,
            default: true,
            defaults: defaults
        )
    }

    // MARK: - Reading

    /// Public, cookie-less, credential-free GET. A failure is nil, never a
    /// half-parsed catalog: an unreadable reading must not rewrite the
    /// baseline, or the next successful poll would report every model as new.
    static func fetchCatalog() async -> Snapshot? {
        do {
            let result = try await Usage.get(modelsURL, headers: [:])
            guard (200..<300).contains(result.status) else {
                Log.model.error("openrouter catalog HTTP \(result.status)")
                return nil
            }
            return parse(result.body)
        } catch {
            Log.model.error("openrouter catalog request failed")
            return nil
        }
    }

    /// `$0 prompt` AND `$0 completion` — a model that is free to read but not
    /// to answer is not free, and neither is a price Tachyon cannot read.
    /// Those land in `paid` so a later genuine drop still reads as
    /// BECAME_FREE rather than as a brand-new launch.
    static func parse(_ data: Data) -> Snapshot? {
        let entries = JSONValue.parse(data)["data"].array
        guard !entries.isEmpty else { return nil }

        var snapshot = Snapshot()
        for entry in entries {
            guard let id = entry["id"].string, !id.isEmpty else { continue }
            if entry["pricing"]["prompt"].double == 0,
               entry["pricing"]["completion"].double == 0 {
                snapshot.free[id] = model(from: entry, id: id)
            } else {
                snapshot.paid.insert(id)
            }
        }
        return snapshot
    }

    private static func model(from entry: JSONValue, id: String) -> Model {
        let architecture = entry["architecture"]
        return Model(
            id: id,
            name: entry["name"].string ?? id,
            contextLength: entry["context_length"].int,
            created: entry["created"].epochDate,
            inputModalities: architecture["input_modalities"].array.compactMap(\.string),
            outputModalities: architecture["output_modalities"].array.compactMap(\.string)
        )
    }

    // MARK: - Diffing

    /// Nil previous means "first reading ever". OpenRouter already lists a
    /// couple of dozen free models, so the baseline run must stay silent —
    /// otherwise enabling this would bury the user in stale news.
    static func changes(from previous: Snapshot?, to current: Snapshot) -> [Change] {
        guard let previous else { return [] }
        return current.free
            .filter { previous.free[$0.key] == nil }
            .map { change(for: $0.value, in: previous) }
            .sorted { $0.model.id < $1.model.id }
    }

    private static func change(for model: Model, in previous: Snapshot) -> Change {
        if previous.paid.contains(model.id) { return .becameFree(model) }
        if let base = freeVariantBase(of: model.id), previous.paid.contains(base) {
            return .freeVariantAdded(model)
        }
        return .newFree(model)
    }

    private static func freeVariantBase(of id: String) -> String? {
        guard id.hasSuffix(":free") else { return nil }
        let base = String(id.dropLast(":free".count))
        return base.isEmpty ? nil : base
    }

    // MARK: - Notification text

    static func message(for changes: [Change], now: Date = Date()) -> Message? {
        if let only = changes.first, changes.count == 1 {
            return singleMessage(for: only, now: now)
        }
        guard !changes.isEmpty else { return nil }
        let listed = changes.prefix(5).map(\.model.name).joined(separator: ", ")
        let overflow = changes.count > 5 ? " +\(changes.count - 5) more" : ""
        return Message(
            title: "\(changes.count) new free OpenRouter models",
            body: listed + overflow
        )
    }

    private static func singleMessage(for change: Change, now: Date) -> Message {
        let model = change.model
        let title: String
        switch change {
        case .newFree:
            title = "New free model on OpenRouter"
        case .becameFree:
            title = "\(model.name) is now free"
        case .freeVariantAdded:
            title = "New free variant: \(model.name)"
        }
        return Message(title: title, body: body(for: model, now: now))
    }

    private static func body(for model: Model, now: Date) -> String {
        var lines = [model.id]
        if let context = model.contextLength {
            lines.append("\(context.formatted()) context")
        }
        if !model.inputModalities.isEmpty || !model.outputModalities.isEmpty {
            let input = model.inputModalities.isEmpty
                ? "–" : model.inputModalities.joined(separator: "+")
            let output = model.outputModalities.isEmpty
                ? "–" : model.outputModalities.joined(separator: "+")
            lines.append("\(input) in · \(output) out")
        }
        if let created = model.created {
            lines.append("Released \(ResetFormat.relative(created, now: now))")
        }
        lines.append("$0 in · $0 out")
        return lines.joined(separator: "\n")
    }

    // MARK: - Baseline persistence

    static func load(defaults: UserDefaults = Settings.defaults) -> Snapshot? {
        guard let data = Settings.dataSetting(
            snapshotKey, provider: OpenRouterProvider.providerID, defaults: defaults
        ) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    static func save(_ snapshot: Snapshot, defaults: UserDefaults = Settings.defaults) {
        Settings.setDataSetting(
            try? JSONEncoder().encode(snapshot),
            suffix: snapshotKey,
            provider: OpenRouterProvider.providerID,
            defaults: defaults
        )
    }
}
