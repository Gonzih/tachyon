import Foundation
import XCTest
@testable import Tachyon

final class FreeModelWatchTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "dev.gonzih.tachyon.tests.freeModelWatch"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults = nil
        super.tearDown()
    }

    // MARK: - Parsing

    func testParsesFreeAndPaidModelsFromRealPayloadShape() throws {
        let data = Self.catalog(
            free: [Self.entry(id: "stealth/space-bunny-alpha", name: "Space Bunny Alpha",
                              prompt: "0", completion: "0", context: 1_000_000,
                              created: 1_790_950_024,
                              input: ["text", "image"], output: ["text"])],
            paid: [Self.entry(id: "openai/gpt-5", prompt: "0.0000015", completion: "0.000006")]
        )

        let snapshot = try XCTUnwrap(FreeModelWatch.parse(data))

        XCTAssertEqual(Array(snapshot.free.keys), ["stealth/space-bunny-alpha"])
        XCTAssertEqual(snapshot.paid, ["openai/gpt-5"])
        let bunny = try XCTUnwrap(snapshot.free["stealth/space-bunny-alpha"])
        XCTAssertEqual(bunny.name, "Space Bunny Alpha")
        XCTAssertEqual(bunny.contextLength, 1_000_000)
        XCTAssertEqual(bunny.inputModalities, ["text", "image"])
        XCTAssertEqual(bunny.outputModalities, ["text"])
        XCTAssertEqual(bunny.created, Date(timeIntervalSince1970: 1_790_950_024))
    }

    /// Free to read but not to answer is not free. A model Tachyon cannot
    /// price at all is not free either, and must not be reported as one.
    func testRequiresBothPricesToBeZero() throws {
        let data = Self.catalog(
            free: [],
            paid: [
                Self.entry(id: "half/free", prompt: "0", completion: "0.0000004"),
                Self.entry(id: "priced/missing", prompt: nil, completion: nil),
                Self.entry(id: "negative/router", prompt: "-1", completion: "-1"),
            ]
        )

        let snapshot = try XCTUnwrap(FreeModelWatch.parse(data))

        XCTAssertTrue(snapshot.free.isEmpty)
        XCTAssertEqual(snapshot.paid, ["half/free", "priced/missing", "negative/router"])
    }

    func testRejectsUnreadablePayload() {
        XCTAssertNil(FreeModelWatch.parse(Data("not json".utf8)))
        XCTAssertNil(FreeModelWatch.parse(Self.catalog(free: [], paid: [])))
    }

    // MARK: - Diffing

    /// The baseline run must be silent: OpenRouter already lists ~22 free
    /// models, and replaying them on first launch is noise, not news.
    func testFirstReadingRecordsBaselineWithoutAlerting() {
        let current = snapshot(free: ["a/one": model("a/one")], paid: ["a/two"])
        XCTAssertEqual(FreeModelWatch.changes(from: nil, to: current), [])
    }

    func testDetectsNewFreeModel() {
        let previous = snapshot(free: ["a/one": model("a/one")], paid: ["a/two"])
        let current = snapshot(
            free: [
                "a/one": model("a/one"),
                "stealth/space-bunny-alpha": model("stealth/space-bunny-alpha"),
            ],
            paid: ["a/two"]
        )

        let changes = FreeModelWatch.changes(from: previous, to: current)

        XCTAssertEqual(changes, [.newFree(model("stealth/space-bunny-alpha"))])
    }

    func testDetectsPaidModelBecomingFree() {
        let previous = snapshot(free: [:], paid: ["a/one"])
        let current = snapshot(free: ["a/one": model("a/one")], paid: [])

        let changes = FreeModelWatch.changes(from: previous, to: current)

        XCTAssertEqual(changes, [.becameFree(model("a/one"))])
    }

    func testDetectsFreeVariantOfKnownModel() {
        let previous = snapshot(free: [:], paid: ["qwen/qwen3-8b"])
        let current = snapshot(free: ["qwen/qwen3-8b:free": model("qwen/qwen3-8b:free")], paid: ["qwen/qwen3-8b"])

        let changes = FreeModelWatch.changes(from: previous, to: current)

        XCTAssertEqual(changes, [.freeVariantAdded(model("qwen/qwen3-8b:free"))])
    }

    /// A `:free` id for a base Tachyon never saw is a new model, not a variant
    /// of something it can vouch for.
    func testFreeVariantOfUnknownBaseIsANewModel() {
        let previous = snapshot(free: [:], paid: [])
        let current = snapshot(free: ["ghost/base:free": model("ghost/base:free")], paid: [])

        XCTAssertEqual(
            FreeModelWatch.changes(from: previous, to: current),
            [.newFree(model("ghost/base:free"))]
        )
    }

    /// A model that goes back to being paid is not news about free models.
    func testIgnoresModelsThatStopBeingFree() {
        let previous = snapshot(free: ["a/one": model("a/one")], paid: [])
        let current = snapshot(free: [:], paid: ["a/one"])

        XCTAssertEqual(FreeModelWatch.changes(from: previous, to: current), [])
    }

    func testUnchangedCatalogProducesNoChanges() {
        let catalog = snapshot(free: ["a/one": model("a/one")], paid: ["a/two"])

        XCTAssertEqual(FreeModelWatch.changes(from: catalog, to: catalog), [])
    }

    // MARK: - Message

    func testMessageNamesModelAndShowsOnlyReportedFacts() throws {
        let bunny = FreeModelWatch.Model(
            id: "stealth/space-bunny-alpha",
            name: "Space Bunny Alpha",
            contextLength: 1_000_000,
            created: Date(timeIntervalSince1970: 900),
            inputModalities: ["text", "image"],
            outputModalities: ["text"]
        )
        let now = Date(timeIntervalSince1970: 960)

        let message = try XCTUnwrap(FreeModelWatch.message(for: [.newFree(bunny)], now: now))

        XCTAssertEqual(message.title, "New free model on OpenRouter")
        XCTAssertEqual(message.body, """
        stealth/space-bunny-alpha
        1,000,000 context
        text+image in · text out
        Released 1m ago
        $0 in · $0 out
        """)
    }

    func testMessageOmitsUnknownFactsRatherThanGuessing() throws {
        let bare = FreeModelWatch.Model(
            id: "a/bare", name: "A Bare", contextLength: nil,
            created: nil, inputModalities: [], outputModalities: []
        )

        let message = try XCTUnwrap(FreeModelWatch.message(for: [.newFree(bare)]))

        XCTAssertEqual(message.body, "a/bare\n$0 in · $0 out")
    }

    func testMessageDistinguishesTransitions() throws {
        let one = model("a/one")
        XCTAssertEqual(
            try XCTUnwrap(FreeModelWatch.message(for: [.becameFree(one)])).title,
            "one is now free"
        )
        XCTAssertEqual(
            try XCTUnwrap(FreeModelWatch.message(for: [.freeVariantAdded(one)])).title,
            "New free variant: one"
        )
    }

    func testBatchedMessageCountsAndTruncates() throws {
        let changes: [FreeModelWatch.Change] = (1...7).map { .newFree(model("a/\($0)")) }

        let message = try XCTUnwrap(FreeModelWatch.message(for: changes))

        XCTAssertEqual(message.title, "7 new free OpenRouter models")
        XCTAssertEqual(message.body, "1, 2, 3, 4, 5 +2 more")
    }

    func testNoChangesMeansNoNotification() {
        XCTAssertNil(FreeModelWatch.message(for: []))
    }

    /// The watch must read the key the Settings pane writes. Drift here is
    /// silent in the app: the toggle moves, the watch never hears it.
    func testWatchReadsTheKeyTheProviderDeclares() {
        defaults.set(false, forKey: Self.alertsKey)
        XCTAssertFalse(FreeModelWatch.isEnabled(defaults: defaults))

        defaults.set(true, forKey: Self.alertsKey)
        XCTAssertTrue(FreeModelWatch.isEnabled(defaults: defaults))
    }

    // MARK: - Persistence and gating

    /// A lost baseline would replay every currently-free model as brand new.
    func testSnapshotSurvivesRoundTrip() throws {
        let catalog = snapshot(free: ["a/one": model("a/one")], paid: ["a/two", "a/three"])

        FreeModelWatch.save(catalog, defaults: defaults)

        XCTAssertEqual(FreeModelWatch.load(defaults: defaults), catalog)
    }

    func testMissingSnapshotIsNilNotEmpty() {
        XCTAssertNil(FreeModelWatch.load(defaults: defaults))
    }

    func testAlertIsOnByDefault() {
        XCTAssertTrue(FreeModelWatch.isEnabled(defaults: defaults))
    }

    private static var alertsKey: String {
        "provider.\(OpenRouterProvider.providerID).\(OpenRouterProvider.freeModelAlertsKey)"
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

    private func snapshot(free: [String: FreeModelWatch.Model], paid: Set<String>) -> FreeModelWatch.Snapshot {
        FreeModelWatch.Snapshot(free: free, paid: paid)
    }

    private static func catalog(free: [String], paid: [String]) -> Data {
        let entries = free + paid
        return Data("{\"data\":[\(entries.joined(separator: ","))]}".utf8)
    }

    private static func entry(
        id: String,
        name: String? = nil,
        prompt: String?,
        completion: String?,
        context: Int = 128_000,
        created: Int? = 1_700_000_000,
        input: [String] = ["text"],
        output: [String] = ["text"]
    ) -> String {
        func quoted(_ value: String?) -> String {
            value.map { "\"\($0)\"" } ?? "null"
        }
        // Built outside the interpolation: an escaped quote inside a
        // multiline literal's interpolation would reach the JSON verbatim.
        let inputJSON = input.map { "\"\($0)\"" }.joined(separator: ",")
        let outputJSON = output.map { "\"\($0)\"" }.joined(separator: ",")
        return """
        {"id":"\(id)","name":"\(name ?? id)","created":\(created ?? 0),\
        "context_length":\(context),\
        "architecture":{"input_modalities":[\(inputJSON)],\
        "output_modalities":[\(outputJSON)]},\
        "pricing":{"prompt":\(quoted(prompt)),"completion":\(quoted(completion))}}
        """
    }
}
