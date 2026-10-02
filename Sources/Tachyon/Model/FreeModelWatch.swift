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
    struct Model: Sendable, Equatable, Codable {
        let id: String
        let name: String
        let contextLength: Int?
        /// When OpenRouter listed the entry — not necessarily when the vendor
        /// released the model.
        let created: Date?
        let inputModalities: [String]
        let outputModalities: [String]
    }

    /// The diff Tachyon reports. Every case means "this model is $0 now".
    /// Tachyon never claims a model left the catalog or that it will stay
    /// free, and `nowFree` deliberately declines to claim a price *drop* it
    /// could not observe.
    enum Change: Sendable, Equatable {
        /// An id Tachyon had never seen, at $0.
        case newFree(Model)
        /// A model Tachyon had already seen at a readable nonzero price, now $0.
        case becameFree(Model)
        /// A model whose pricing Tachyon could not read before, now $0.
        /// No transition was observed, so the wording claims only presence.
        case nowFree(Model)
        /// A `:free` id appeared for a base model already in the catalog.
        case freeVariantAdded(Model)

        var model: Model {
            switch self {
            case .newFree(let model),
                 .becameFree(let model),
                 .nowFree(let model),
                 .freeVariantAdded(let model):
                return model
            }
        }
    }

    /// One catalog reading, partitioned so every later claim is supportable.
    /// `free` carries the full record because a notification needs the name and
    /// context length; the other two are ids only.
    ///
    /// `unpriced` exists so a price Tachyon could not read is never mistaken
    /// for a price that was read and found nonzero.
    struct Snapshot: Sendable, Equatable, Codable {
        /// Priced $0 for every readable field.
        var free: [String: Model] = [:]
        /// Priced, and read as nonzero.
        var paid: Set<String> = []
        /// Listed, but Tachyon could not read its pricing.
        var unpriced: Set<String> = []
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

    enum PriceVerdict: Sendable, Equatable {
        /// Every readable pricing field is exactly zero.
        case free
        /// At least one readable field is nonzero — including a negative price,
        /// which is a router credit, not a free model.
        case paid
        /// No readable pricing field at all.
        case unreadable
    }

    /// Free means *every* price Tachyon can read is zero, not just the token
    /// pair. The catalog also carries `image`, `audio`, `audio_output`,
    /// `web_search` and cache fields, so $0 tokens with a per-image fee is not
    /// free. `overrides` is a list of tiered prices keyed by
    /// `min_prompt_tokens`, so it nests further prices rather than being
    /// noise: a $0 base price with a paid tier above a threshold is not free.
    static func price(of entry: JSONValue) -> PriceVerdict {
        let pricing = entry["pricing"]
        guard pricing.exists else { return .unreadable }
        var readAny = false
        for number in numericPrices(of: pricing) {
            readAny = true
            if number != 0 { return .paid }
        }
        return readAny ? .free : .unreadable
    }

    /// `min_prompt_tokens` is a tier threshold, not a price — counting it
    /// would make every tiered model look paid.
    private static let nonPriceKeys: Set<String> = ["min_prompt_tokens"]

    /// Every finite number reachable inside a pricing value, at any depth, so
    /// an `overrides` tier cannot hide behind a numeric-looking parent.
    private static func numericPrices(of value: JSONValue, key: String? = nil) -> [Double] {
        if let key, nonPriceKeys.contains(key) { return [] }
        if let number = value.double { return [number] }
        if let dictionary = value.raw as? [String: Any] {
            return dictionary.flatMap { numericPrices(of: JSONValue($0.value), key: $0.key) }
        }
        return value.array.flatMap { numericPrices(of: $0) }
    }

    /// A catalog in which not one price was readable means the schema moved,
    /// not that every model became free. Returning nil keeps the old baseline
    /// instead of demoting 22 free models to `unpriced` and re-alerting on the
    /// next well-formed poll.
    static func parse(_ data: Data) -> Snapshot? {
        let entries = JSONValue.parse(data)["data"].array
        guard !entries.isEmpty else { return nil }

        var snapshot = Snapshot()
        var readAnyPrice = false
        for entry in entries {
            guard let id = entry["id"].string, !id.isEmpty else { continue }
            switch price(of: entry) {
            case .free:
                readAnyPrice = true
                snapshot.free[id] = model(from: entry, id: id)
            case .paid:
                readAnyPrice = true
                snapshot.paid.insert(id)
            case .unreadable:
                snapshot.unpriced.insert(id)
            }
        }
        guard readAnyPrice else { return nil }
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

    /// Absence is not evidence. An id missing from this poll keeps the bucket
    /// it had last time, so a truncated catalog cannot shrink the baseline and
    /// make every long-standing free model look new on the next full poll.
    /// An id present as `paid` still moves out, so a genuine price drop is
    /// reported.
    ///
    /// The cost is that a delisted id is remembered forever, so the baseline
    /// grows slowly with catalog churn. At ~465 entries today that is a few KB
    /// of ids; it is the right trade against replaying the catalog as news.
    static func merged(current: Snapshot, preserving previous: Snapshot?) -> Snapshot {
        guard let previous else { return current }

        var current = current
        // A known model that briefly ships an unreadable pricing block is not
        // evidence of anything. Treat it as absent rather than letting it fall
        // into `unpriced`, which would replay stale news once prices recover.
        for id in current.unpriced
        where previous.free[id] != nil || previous.paid.contains(id) {
            current.unpriced.remove(id)
        }

        func isAbsent(_ id: String) -> Bool {
            current.free[id] == nil
                && current.paid.contains(id) == false
                && current.unpriced.contains(id) == false
        }
        var merged = current
        // An id present in any current bucket already has a fresh reading and
        // is never carried forward — otherwise a model the catalog still
        // reports as paid would land in `free` as well.
        for (id, model) in previous.free where isAbsent(id) { merged.free[id] = model }
        for id in previous.paid where isAbsent(id) { merged.paid.insert(id) }
        for id in previous.unpriced where isAbsent(id) { merged.unpriced.insert(id) }
        return merged
    }

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
        if previous.unpriced.contains(model.id) { return .nowFree(model) }
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
        case .nowFree:
            title = "\(model.name) is free on OpenRouter"
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
            // `created` is the catalog entry's timestamp, so this is when
            // OpenRouter listed it. The vendor may have shipped it earlier.
            lines.append("Listed \(ResetFormat.relative(created, now: now))")
        }
        lines.append("$0 in · $0 out")
        return lines.joined(separator: "\n")
    }

    // MARK: - Baseline persistence

    static func load(defaults: UserDefaults = Settings.defaults) -> Snapshot? {
        guard let data = Settings.dataSetting(
            snapshotKey, provider: OpenRouterProvider.providerID, defaults: defaults
        ) else { return nil }
        guard let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            // A stored baseline that no longer decodes — a shape change between
            // versions — is not the same as a fresh install. Say so instead of
            // letting the next poll re-baseline in silence.
            Log.model.error("openrouter free-model baseline unreadable")
            return nil
        }
        return snapshot
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
