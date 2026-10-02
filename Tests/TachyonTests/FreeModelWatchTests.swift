import Foundation
import XCTest
@testable import Tachyon

final class FreeModelWatchTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName = ""

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "dev.gonzih.tachyon.tests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        if !suiteName.isEmpty {
            defaults?.removePersistentDomain(forName: suiteName)
            suiteName = ""
        }
        defaults = nil
        super.tearDown()
    }

    // MARK: - Parsing

    func testParsesFreeAndPaidModelsFromRealPayloadShape() throws {
        let data = Self.catalog([
            Self.free("stealth/space-bunny-alpha", name: "Space Bunny Alpha", context: 1_000_000,
                      created: 1_790_950_024, input: ["text", "image"], output: ["text"]),
            Self.priced("openai/gpt-5", prompt: "0.0000015", completion: "0.000006"),
        ])

        let snapshot = try XCTUnwrap(FreeModelWatch.parse(data))

        XCTAssertEqual(Array(snapshot.free.keys), ["stealth/space-bunny-alpha"])
        XCTAssertEqual(snapshot.paid, ["openai/gpt-5"])
        XCTAssertTrue(snapshot.unpriced.isEmpty)
        let bunny = try XCTUnwrap(snapshot.free["stealth/space-bunny-alpha"])
        XCTAssertEqual(bunny.name, "Space Bunny Alpha")
        XCTAssertEqual(bunny.contextLength, 1_000_000)
        XCTAssertEqual(bunny.inputModalities, ["text", "image"])
        XCTAssertEqual(bunny.outputModalities, ["text"])
        XCTAssertEqual(bunny.created, Date(timeIntervalSince1970: 1_790_950_024))
    }

    /// The API sends prices as decimal strings today, but a numeric `0` means
    /// the same thing and must not be read as unreadable.
    func testNumericZeroPriceIsStillFree() throws {
        let data = Self.catalog([Self.priced("a/numeric", prompt: 0, completion: 0)])

        let snapshot = try XCTUnwrap(FreeModelWatch.parse(data))

        XCTAssertEqual(Array(snapshot.free.keys), ["a/numeric"])
    }

    /// Free to read but not to answer is not free, and a negative price is a
    /// router credit rather than a giveaway.
    func testRequiresEveryReadablePriceToBeZero() throws {
        let data = Self.catalog([
            Self.priced("half/free", prompt: 0, completion: "0.0000004"),
            Self.priced("negative/router", prompt: -1, completion: -1),
        ])

        let snapshot = try XCTUnwrap(FreeModelWatch.parse(data))

        XCTAssertTrue(snapshot.free.isEmpty)
        XCTAssertEqual(snapshot.paid, ["half/free", "negative/router"])
    }

    /// The live catalog carries `image`, `audio`, `audio_output`,
    /// `web_search` and cache fields. $0 tokens plus a per-image fee is not
    /// free, and announcing it as free would be a false claim.
    func testNonZeroNonTokenPriceDisqualifiesAModel() throws {
        let data = Self.catalog([
            Self.priced("vendor/imaged", prompt: 0, completion: 0, extra: ["image": "0.0072"]),
            Self.priced("vendor/cheap-images", prompt: 0, completion: 0,
                        extra: ["image": "0", "web_search": "0.005"]),
        ])

        let snapshot = try XCTUnwrap(FreeModelWatch.parse(data))

        XCTAssertTrue(snapshot.free.isEmpty)
        XCTAssertEqual(snapshot.paid, ["vendor/imaged", "vendor/cheap-images"])
    }

    /// `overrides` is a list of tiered prices, not a non-price object: a $0
    /// base price with a paid tier above a threshold is not free.
    func testPaidTierInsideOverridesDisqualifiesAModel() throws {
        let data = Self.catalog([
            Self.priced("a/tiered", prompt: 0, completion: 0, extra: [
                "overrides": "[{\"min_prompt_tokens\":272000,\"prompt\":\"0.000004\",\"completion\":\"0.000015\"}]",
            ]),
        ])

        let snapshot = try XCTUnwrap(FreeModelWatch.parse(data))

        XCTAssertTrue(snapshot.free.isEmpty)
        XCTAssertEqual(snapshot.paid, ["a/tiered"])
    }

    /// `min_prompt_tokens` is a threshold, not a price. Counting it would mark
    /// every tiered model paid regardless of its rates.
    func testTierThresholdAloneDoesNotDisqualifyAModel() throws {
        let data = Self.catalog([
            Self.priced("a/zero-tiers", prompt: 0, completion: 0, extra: [
                "overrides": "[{\"min_prompt_tokens\":200000,\"prompt\":\"0\",\"completion\":\"0\"}]",
            ]),
        ])

        let snapshot = try XCTUnwrap(FreeModelWatch.parse(data))

        XCTAssertEqual(Array(snapshot.free.keys), ["a/zero-tiers"])
    }

    func testUnreadablePricingIsKeptDistinctFromPaid() throws {
        let data = Self.catalog([
            Self.priced("a/missing", prompt: nil, completion: nil),
            Self.free("a/free"),
        ])

        let snapshot = try XCTUnwrap(FreeModelWatch.parse(data))

        XCTAssertEqual(snapshot.unpriced, ["a/missing"])
        XCTAssertTrue(snapshot.paid.isEmpty)
    }

    /// If not one price in the whole catalog was readable, the schema moved.
    /// Returning a snapshot would demote every known free model to `unpriced`
    /// and re-alert on all of them once the shape returns.
    func testCatalogWithNoReadablePriceIsRejectedEntirely() {
        let data = Self.catalog([
            Self.priced("a/one", prompt: nil, completion: nil),
            Self.priced("a/two", prompt: nil, completion: nil),
        ])

        XCTAssertNil(FreeModelWatch.parse(data))
    }

    func testRejectsUnreadablePayload() {
        XCTAssertNil(FreeModelWatch.parse(Data("not json".utf8)))
        XCTAssertNil(FreeModelWatch.parse(Self.catalog([])))
    }

    // MARK: - Baseline merging

    /// A truncated 200 must not shrink the baseline: the next full poll would
    /// otherwise report every long-standing free model as brand new.
    func testTruncatedCatalogDoesNotForgetKnownFreeModels() throws {
        let full = snapshot(
            free: ["a/one": model("a/one"), "a/two": model("a/two")],
            paid: ["a/three"],
            unpriced: ["a/four"]
        )
        let truncated = snapshot(free: ["a/one": model("a/one")], paid: [], unpriced: [])

        let merged = FreeModelWatch.merged(current: truncated, preserving: full)

        XCTAssertEqual(merged, full)
        XCTAssertEqual(FreeModelWatch.changes(from: full, to: merged), [])
    }

    /// A known free model that briefly ships an unreadable pricing block must
    /// not be demoted to `unpriced`, or recovering prices would replay it as
    /// fresh news for a model that has been free all along.
    func testKnownModelWithTransientUnreadablePricingKeepsItsBucket() {
        let previous = snapshot(free: ["a/one": model("a/one")], paid: [], unpriced: [])
        let current = snapshot(free: [:], paid: [], unpriced: ["a/one"])

        let merged = FreeModelWatch.merged(current: current, preserving: previous)

        XCTAssertEqual(Array(merged.free.keys), ["a/one"])
        XCTAssertTrue(merged.unpriced.isEmpty)
        XCTAssertEqual(FreeModelWatch.changes(from: previous, to: merged), [])
    }

    /// A model never seen before with unreadable pricing stays genuinely
    /// unpriced — there is nothing to carry forward.
    func testUnknownModelWithUnreadablePricingStaysUnpriced() {
        let previous = snapshot(free: [:], paid: [], unpriced: [])
        let current = snapshot(free: [:], paid: [], unpriced: ["a/new"])

        let merged = FreeModelWatch.merged(current: current, preserving: previous)

        XCTAssertEqual(merged.unpriced, ["a/new"])
    }

    /// Each id must live in exactly one bucket: a model the catalog still
    /// reports as paid cannot also linger in `free` because of a carry-forward.
    /// A genuine price drop is still reported.
    func testMergingHonorsARealPriceDropWithoutDuplicatingBuckets() {
        let previous = snapshot(free: ["a/one": model("a/one")], paid: ["a/two"], unpriced: [])
        let current = snapshot(free: ["a/two": model("a/two")], paid: ["a/one"], unpriced: [])

        let merged = FreeModelWatch.merged(current: current, preserving: previous)

        XCTAssertEqual(merged, current)
        XCTAssertFalse(merged.free.keys.contains("a/one"))
        XCTAssertEqual(
            FreeModelWatch.changes(from: previous, to: merged),
            [.becameFree(model("a/two"))]
        )
    }

    func testMergingWithoutAPreviousSnapshotIsIdentity() {
        let current = snapshot(free: ["a/one": model("a/one")], paid: [], unpriced: [])

        XCTAssertEqual(FreeModelWatch.merged(current: current, preserving: nil), current)
    }

    // MARK: - Diffing

    /// The baseline run must be silent: OpenRouter already lists ~22 free
    /// models, and replaying them on first launch is noise, not news.
    func testFirstReadingRecordsBaselineWithoutAlerting() {
        let current = snapshot(free: ["a/one": model("a/one")], paid: ["a/two"], unpriced: [])
        XCTAssertEqual(FreeModelWatch.changes(from: nil, to: current), [])
    }

    /// Most free models launch already-free and never pass through a paid
    /// price, so "a new id at $0" is the signal that matters. Someone who
    /// installs the day one launches must still hear about it.
    func testFirstRunAlertsAboutAModelThatLaunchedFreeToday() {
        let now = Date(timeIntervalSince1970: 1_790_174_884)
        let fresh = FreeModelWatch.Model(
            id: "inclusionai/ling-3.1-flash",
            name: "inclusionAI: Ling 3.1 Flash",
            contextLength: 262_144,
            created: now.addingTimeInterval(-3_600),
            inputModalities: ["text"],
            outputModalities: ["text"]
        )
        let old = model("a/old")

        let changes = FreeModelWatch.changes(
            from: nil,
            to: snapshot(free: [fresh.id: fresh, old.id: old], paid: [], unpriced: []),
            now: now
        )

        XCTAssertEqual(changes, [.newFree(fresh)])
    }

    /// A model older than the window is not news, however long it has been free.
    func testFirstRunIgnoresModelsOlderThanTheRecencyWindow() {
        let now = Date(timeIntervalSince1970: 1_790_174_884)
        let stale = FreeModelWatch.Model(
            id: "a/stale", name: "A Stale", contextLength: nil,
            created: now.addingTimeInterval(-FreeModelWatch.firstRunRecency - 60),
            inputModalities: [], outputModalities: []
        )

        XCTAssertEqual(
            FreeModelWatch.changes(
                from: nil, to: snapshot(free: [stale.id: stale], paid: [], unpriced: []), now: now
            ),
            []
        )
    }

    /// No timestamp means no claim. Tachyon cannot call a model new on the
    /// strength of a field the catalog did not supply.
    func testFirstRunStaysSilentWithoutAListingDate() {
        let now = Date(timeIntervalSince1970: 1_790_174_884)
        let undated = FreeModelWatch.Model(
            id: "a/undated", name: "A Undated", contextLength: nil,
            created: nil, inputModalities: [], outputModalities: []
        )

        XCTAssertEqual(
            FreeModelWatch.changes(
                from: nil, to: snapshot(free: [undated.id: undated], paid: [], unpriced: []), now: now
            ),
            []
        )
    }

    func testDetectsNewFreeModel() {
        let previous = snapshot(free: ["a/one": model("a/one")], paid: ["a/two"], unpriced: [])
        let current = snapshot(
            free: [
                "a/one": model("a/one"),
                "stealth/space-bunny-alpha": model("stealth/space-bunny-alpha"),
            ],
            paid: ["a/two"],
            unpriced: []
        )

        XCTAssertEqual(
            FreeModelWatch.changes(from: previous, to: current),
            [.newFree(model("stealth/space-bunny-alpha"))]
        )
    }

    func testDetectsPaidModelBecomingFree() {
        let previous = snapshot(free: [:], paid: ["a/one"], unpriced: [])
        let current = snapshot(free: ["a/one": model("a/one")], paid: [], unpriced: [])

        XCTAssertEqual(FreeModelWatch.changes(from: previous, to: current), [.becameFree(model("a/one"))])
    }

    /// A model whose price could not be read has no observed transition, so it
    /// must not borrow the "is now free" wording.
    func testUnpricedModelBecomingFreeClaimsNoTransition() {
        let previous = snapshot(free: [:], paid: [], unpriced: ["a/one"])
        let current = snapshot(free: ["a/one": model("a/one")], paid: [], unpriced: [])

        let changes = FreeModelWatch.changes(from: previous, to: current)

        XCTAssertEqual(changes, [.nowFree(model("a/one"))])
        XCTAssertEqual(changes.first?.model.name, "one")
    }

    func testDetectsFreeVariantOfKnownModel() {
        let previous = snapshot(free: [:], paid: ["qwen/qwen3-8b"], unpriced: [])
        let current = snapshot(
            free: ["qwen/qwen3-8b:free": model("qwen/qwen3-8b:free")],
            paid: ["qwen/qwen3-8b"],
            unpriced: []
        )

        XCTAssertEqual(
            FreeModelWatch.changes(from: previous, to: current),
            [.freeVariantAdded(model("qwen/qwen3-8b:free"))]
        )
    }

    /// A `:free` id for a base Tachyon never saw is a new model, not a variant
    /// of something it can vouch for.
    func testFreeVariantOfUnknownBaseIsANewModel() {
        let previous = snapshot(free: [:], paid: [], unpriced: [])
        let current = snapshot(free: ["ghost/base:free": model("ghost/base:free")], paid: [], unpriced: [])

        XCTAssertEqual(
            FreeModelWatch.changes(from: previous, to: current),
            [.newFree(model("ghost/base:free"))]
        )
    }

    /// The base was already free, so the variant is genuinely new rather than a
    /// price drop on the base.
    func testFreeVariantOfAlreadyFreeBaseIsStillANewModel() {
        let previous = snapshot(free: ["qwen/base": model("qwen/base")], paid: [], unpriced: [])
        let current = snapshot(
            free: [
                "qwen/base": model("qwen/base"),
                "qwen/base:free": model("qwen/base:free"),
            ],
            paid: [],
            unpriced: []
        )

        XCTAssertEqual(
            FreeModelWatch.changes(from: previous, to: current),
            [.newFree(model("qwen/base:free"))]
        )
    }

    /// A model that goes back to being paid is not news about free models.
    func testIgnoresModelsThatStopBeingFree() {
        let previous = snapshot(free: ["a/one": model("a/one")], paid: [], unpriced: [])
        let current = snapshot(free: [:], paid: ["a/one"], unpriced: [])

        XCTAssertEqual(FreeModelWatch.changes(from: previous, to: current), [])
    }

    func testUnchangedCatalogProducesNoChanges() {
        let catalog = snapshot(free: ["a/one": model("a/one")], paid: ["a/two"], unpriced: ["a/three"])

        XCTAssertEqual(FreeModelWatch.changes(from: catalog, to: catalog), [])
    }

    // MARK: - Message

    /// The catalog's own model card leads with the model's name, then the id,
    /// then a price / context / modalities row. Tachyon mirrors that. Every
    /// fact lives in the body: a macOS subtitle displaces the body entirely in
    /// a collapsed banner, which is where an alert is actually read.
    func testMessageMirrorsTheCatalogModelCard() throws {
        let bunny = FreeModelWatch.Model(
            id: "stealth/space-bunny-alpha",
            name: "Space Bunny Alpha",
            contextLength: 1_000_000,
            created: Date(timeIntervalSince1970: 1_790_174_884),
            inputModalities: ["text", "image", "video"],
            outputModalities: ["text"]
        )

        let message = try XCTUnwrap(FreeModelWatch.message(for: [.newFree(bunny)]))

        XCTAssertEqual(message.title, "New free model: Space Bunny Alpha")
        XCTAssertEqual(message.body, """
        stealth/space-bunny-alpha
        Free · 1M context · accepts 🔤🖼🎥
        Listed Sep 23, 2026
        """)
    }

    func testMessageOmitsUnknownFactsRatherThanGuessing() throws {
        let bare = FreeModelWatch.Model(
            id: "a/bare", name: "A Bare", contextLength: nil,
            created: nil, inputModalities: [], outputModalities: []
        )

        let message = try XCTUnwrap(FreeModelWatch.message(for: [.newFree(bare)]))

        // Only the id and the fact Tachyon actually verified survive.
        XCTAssertEqual(message.body, "a/bare\nFree")
    }

    /// A glyph must never stand in for a modality Tachyon cannot name — an
    /// unrecognized one shows its own name rather than silently vanishing.
    func testUnknownModalityKeepsItsOwnName() throws {
        let odd = FreeModelWatch.Model(
            id: "a/odd", name: "A Odd", contextLength: nil,
            created: nil,
            inputModalities: ["text", "hologram"],
            outputModalities: ["text"]
        )

        let message = try XCTUnwrap(FreeModelWatch.message(for: [.newFree(odd)]))

        XCTAssertEqual(message.body, "a/odd\nFree · accepts 🔤hologram")
    }

    func testMessageDistinguishesTransitions() throws {
        let one = model("a/one")
        XCTAssertEqual(
            try XCTUnwrap(FreeModelWatch.message(for: [.becameFree(one)])).title,
            "one is now free"
        )
        XCTAssertEqual(
            try XCTUnwrap(FreeModelWatch.message(for: [.nowFree(one)])).title,
            "one is free on OpenRouter"
        )
        XCTAssertEqual(
            try XCTUnwrap(FreeModelWatch.message(for: [.freeVariantAdded(one)])).title,
            "New free variant: one"
        )
        XCTAssertEqual(
            try XCTUnwrap(FreeModelWatch.message(for: [.newFree(one)])).title,
            "New free model: one"
        )
    }

    func testBatchedMessageCountsAndTruncates() throws {
        let changes: [FreeModelWatch.Change] = (1...7).map { .newFree(model("a/\($0)")) }

        let message = try XCTUnwrap(FreeModelWatch.message(for: changes))

        XCTAssertEqual(message.title, "7 new free models on OpenRouter")
        XCTAssertEqual(message.body, "1, 2, 3, 4, 5 +2 more")
    }


    func testNoChangesMeansNoNotification() {
        XCTAssertNil(FreeModelWatch.message(for: []))
    }

    // MARK: - Persistence and gating

    /// A lost baseline would replay every currently-free model as brand new.
    func testSnapshotSurvivesRoundTrip() throws {
        let catalog = snapshot(
            free: ["a/one": model("a/one")],
            paid: ["a/two", "a/three"],
            unpriced: ["a/four"]
        )

        FreeModelWatch.save(catalog, defaults: defaults)

        XCTAssertEqual(FreeModelWatch.load(defaults: defaults), catalog)
    }

    func testMissingSnapshotIsNilNotEmpty() {
        XCTAssertNil(FreeModelWatch.load(defaults: defaults))
    }

    /// The watch must honor the same key the Settings pane writes. Drift here
    /// is silent in the app: the toggle moves, the watch never hears it.
    func testAlertFollowsTheToggleTheProviderDeclares() {
        XCTAssertTrue(FreeModelWatch.isEnabled(defaults: defaults))

        defaults.set(
            false,
            forKey: "provider.\(OpenRouterProvider.providerID).\(OpenRouterProvider.freeModelAlertsKey)"
        )
        XCTAssertFalse(FreeModelWatch.isEnabled(defaults: defaults))
    }

    // MARK: - Fixtures

    private func model(_ id: String) -> FreeModelWatch.Model {
        FreeModelWatch.Model(
            id: id,
            name: id.split(separator: "/").last.map(String.init) ?? id,
            contextLength: 8_000,
            created: Date(timeIntervalSince1970: 100),
            inputModalities: ["text"],
            outputModalities: ["text"]
        )
    }

    private func snapshot(
        free: [String: FreeModelWatch.Model],
        paid: Set<String>,
        unpriced: Set<String>
    ) -> FreeModelWatch.Snapshot {
        FreeModelWatch.Snapshot(free: free, paid: paid, unpriced: unpriced)
    }

    private struct Entry {
        let id: String
        let name: String
        let context: Int
        let created: Int
        let input: [String]
        let output: [String]
        let pricing: [String: String]
    }

    private static func free(
        _ id: String,
        name: String? = nil,
        context: Int = 128_000,
        created: Int? = 1_700_000_000,
        input: [String] = ["text"],
        output: [String] = ["text"]
    ) -> Entry {
        priced(
            id, name: name, prompt: "0", completion: "0",
            context: context, created: created, input: input, output: output
        )
    }

    /// Built as a dictionary rather than by string interpolation: escaped
    /// quotes inside a multiline literal's interpolation reach the JSON
    /// verbatim, which silently corrupts numeric-versus-string price coverage.
    private static func priced(
        _ id: String,
        name: String? = nil,
        prompt: Any?,
        completion: Any?,
        extra: [String: String] = [:],
        context: Int = 128_000,
        created: Int? = 1_700_000_000,
        input: [String] = ["text"],
        output: [String] = ["text"]
    ) -> Entry {
        var pricing = extra
        pricing["prompt"] = Self.literal(prompt)
        pricing["completion"] = Self.literal(completion)
        return Entry(
            id: id,
            name: name ?? id,
            context: context,
            created: created ?? 0,
            input: input,
            output: output,
            pricing: pricing
        )
    }

    /// Swift's JSONSerialization distinguishes `0` from `"0"`; the tests must
    /// too, so numbers stay numbers.
    private static func literal(_ value: Any?) -> String {
        switch value {
        case let number as Int: return "\(number)"
        case let text as String: return "\"\(text)\""
        default: return "null"
        }
    }

    private static func catalog(_ entries: [Entry]) -> Data {
        func array(_ values: [String]) -> String {
            "[" + values.map { "\"\($0)\"" }.joined(separator: ",") + "]"
        }
        func object(_ pairs: [(String, String)]) -> String {
            "{" + pairs.map { "\"\($0.0)\":\($0.1)" }.joined(separator: ",") + "}"
        }
        let rendered = entries.map { entry in
            """
            {"id":"\(entry.id)","name":"\(entry.name)","created":\(entry.created),\
            "context_length":\(entry.context),\
            "architecture":{"input_modalities":\(array(entry.input)),\
            "output_modalities":\(array(entry.output))},\
            "pricing":\(object(entry.pricing.map { ($0.key, $0.value) }))}
            """
        }
        return Data("{\"data\":[\(rendered.joined(separator: ","))]}".utf8)
    }
}
