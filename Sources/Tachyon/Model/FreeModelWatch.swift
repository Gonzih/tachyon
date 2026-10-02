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

    /// Most free models launch free and never pass through a paid price, so
    /// "a new id that is already $0" is the primary signal — `becameFree`
    /// catches only the minority that are repriced down later.
    static func changes(
        from previous: Snapshot?,
        to current: Snapshot,
        now: Date = Date()
    ) -> [Change] {
        guard let previous else { return firstRunChanges(from: current, now: now) }
        return current.free
            .filter { previous.free[$0.key] == nil }
            .map { change(for: $0.value, in: previous) }
            .sorted { $0.model.id < $1.model.id }
    }

    /// The first reading must not replay the whole catalog — that would bury a
    /// new user under two dozen models that have been free for months. But a
    /// model that launched free *today* is exactly the news this feature
    /// exists to deliver, and silencing it means anyone who installs after a
    /// launch never hears about it. So a first run speaks up only for models
    /// the catalog says were added within `firstRunRecency`. An unknown
    /// `created` never qualifies: Tachyon cannot claim a model is new when the
    /// timestamp is missing.
    static let firstRunRecency: TimeInterval = 24 * 60 * 60

    private static func firstRunChanges(from current: Snapshot, now: Date) -> [Change] {
        current.free.values
            .filter { model in
                guard let created = model.created else { return false }
                let age = now.timeIntervalSince(created)
                return age >= 0 && age <= firstRunRecency
            }
            .sorted { $0.id < $1.id }
            .map(Change.newFree)
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

    /// macOS renders a collapsed banner as title plus ONE more line. Setting a
    /// subtitle displaces the body entirely, so every fact has to live in the
    /// body — which does wrap and render across as many lines as it needs.
    static func message(for changes: [Change]) -> Message? {
        if let only = changes.first, changes.count == 1 {
            return singleMessage(for: only)
        }
        guard !changes.isEmpty else { return nil }
        let listed = changes.prefix(5).map(\.model.name).joined(separator: ", ")
        let overflow = changes.count > 5 ? " +\(changes.count - 5) more" : ""
        return Message(
            title: "\(changes.count) new free models on OpenRouter",
            body: listed + overflow
        )
    }

    /// The model's own name leads: `stealth/space-bunny-alpha` is the id you
    /// paste into a request, not the thing you recognize.
    private static func singleMessage(for change: Change) -> Message {
        let model = change.model
        let title: String
        switch change {
        case .newFree:
            title = "New free model: \(model.name)"
        case .becameFree:
            title = "\(model.name) is now free"
        case .nowFree:
            title = "\(model.name) is free on OpenRouter"
        case .freeVariantAdded:
            title = "New free variant: \(model.name)"
        }
        return Message(title: title, body: body(for: model))
    }

    /// Mirrors the catalog's own model card: id, then the price / context /
    /// modalities row, then when it was listed.
    private static func body(for model: Model) -> String {
        var lines = [model.id]
        var facts = ["Free"]
        if let context = model.contextLength {
            facts.append("\(compactCount(context)) context")
        }
        if !model.inputModalities.isEmpty {
            facts.append("accepts \(model.inputModalities.map(modalityGlyph).joined(separator: ""))")
        }
        lines.append(facts.joined(separator: " · "))
        if let created = model.created {
            // OpenRouter labels this field "Released" on its own model page.
            // Tachyon says "Listed" because a vendor may ship a model before
            // the catalog gains an entry for it.
            lines.append("Listed \(shortDate(created))")
        }
        return lines.joined(separator: "\n")
    }

    /// The catalog shows bare modality glyphs on its own model card, so the
    /// alert reads the same way as the page it points at. An unrecognized
    /// modality falls through to its own name rather than being dropped: a
    /// glyph must never stand in for something Tachyon cannot name.
    private static func modalityGlyph(_ modality: String) -> String {
        switch modality.lowercased() {
        case "text": return "🔤"
        case "image": return "🖼"
        case "video": return "🎥"
        case "audio": return "🔊"
        case "file": return "📄"
        default: return modality
        }
    }


    /// "Sep 23, 2026" — an absolute date is what a reader compares against
    /// "released last week" on the catalog page. "8d ago" is only meaningful
    /// for the few minutes after the alert, and a notification outlives that.
    private static func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, yyyy"
        return formatter.string(from: date)
    }

    /// 1,000,000 → "1M". A notification is not a place for grouped digits.
    private static func compactCount(_ value: Int) -> String {
        guard value > 0 else { return "0" }
        if value >= 1_000_000 {
            let millions = Double(value) / 1_000_000
            return millions == millions.rounded()
                ? "\(Int(millions))M"
                : String(format: "%.1fM", millions)
        }
        if value >= 1_000 {
            let thousands = Double(value) / 1_000
            return thousands == thousands.rounded()
                ? "\(Int(thousands))K"
                : String(format: "%.1fK", thousands)
        }
        return "\(value)"
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
