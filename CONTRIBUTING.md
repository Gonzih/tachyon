# Contributing a provider

> **If you are a coding agent:** this document is your task spec. Implement one
> file conforming to `UsageProvider`, register it, add a glyph, prove it with
> `swift run Tachyon --smoke`, open a PR titled `provider: <name>`. Everything
> you need is below.

Adding a harness to Tachyon is **one file, one registry line, one glyph**. The
app's whole flywheel is that this stays true, so the protocol is deliberately
small and everything hard — polling, backoff, layout, presence, the popover — is
handled for you.

`Sources/Tachyon/Providers/GrokProvider.swift` is the worked example referenced
throughout. Read it alongside this document.

## The contract

```swift
protocol UsageProvider: Sendable {
    nonisolated var id: String { get }
    nonisolated var displayName: String { get }
    nonisolated var glyph: ProviderGlyph { get }
    nonisolated var pollInterval: TimeInterval { get }
    nonisolated var isExperimental: Bool { get }   // defaulted to false

    func detect() async -> ProviderPresence
    func snapshot() async -> ProviderState
    func start(onExternalChange: @escaping @Sendable () -> Void) async  // defaulted to a no-op
}
```

Two required methods. `detect()` answers *should this harness appear at all*;
`snapshot()` answers *what are the numbers right now*.

### Metadata must be stored `let`s

Under Swift 6 strict concurrency an actor cannot satisfy a `nonisolated`
*computed* requirement, but a stored `let` witnesses one automatically:

```swift
actor GrokProvider: UsageProvider {
    nonisolated let id = "grok"
    nonisolated let displayName = "Grok CLI"
    nonisolated let glyph = ProviderGlyph.grok
    nonisolated let pollInterval: TimeInterval = 120
    nonisolated let isExperimental = true
```

Make your provider an `actor`. Credentials and caches then live in isolated
state with no locking on your part.

## Step 1 — `detect()`

Three outcomes, and the distinction matters to the UI:

| Return | Meaning | UI |
|---|---|---|
| `.notInstalled` | No trace of the harness | Invisible everywhere |
| `.notSignedIn(guidance)` | Harness present, no usable credential | Greyed menu entry showing your guidance |
| `.ready` | Poll me | Gets a ring |

```swift
func detect() async -> ProviderPresence {
    guard Usage.fileExists(Self.home) else { return .notInstalled }
    guard let account = Self.loadAccount() else {
        return .notSignedIn("Run `grok` to sign in")
    }
    if account.isExpired { return .notSignedIn(Self.authGuidance) }
    return .ready
}
```

Guidance strings are shown to the user verbatim, so name the exact command that
fixes the problem. `detect()` re-runs every 60s while a provider is not ready, so
signing in mid-session lights the ring up without a relaunch.

## Step 2 — `snapshot()`

Return one of four states. **Never throw, never crash, never block for long.**

| State | When |
|---|---|
| `.ok(snapshot)` | Live numbers |
| `.stale(snapshot, asOf:)` | Real numbers from a fallback or an older read |
| `.authError(guidance)` | Authentication specifically — nothing else |
| `.unavailable` | Everything else: network down, schema drift, missing file |

That last distinction is a rule, not a preference. `.authError` renders a `!`
badge that tells the user to go run a command; if you return it for a network
blip you have sent them on a pointless errand. Network failures, decode
failures, and missing files are all `.unavailable`, which renders `–`.

```swift
func snapshot() async -> ProviderState {
    guard let account = Self.loadAccount() else {
        if let fallback = Self.logSnapshot() { return .stale(fallback, asOf: fallback.asOf) }
        return .authError(Self.authGuidance)
    }
    do {
        let result = try await Usage.get(Self.billingURL, headers: headers)
        if result.status == 401 || result.status == 403 {
            if let fallback = Self.logSnapshot() { return .stale(fallback, asOf: fallback.asOf) }
            return .authError(Self.authGuidance)
        }
        if (200..<300).contains(result.status),
           let snapshot = Self.decodeBilling(JSONValue.parse(result.body)["config"], asOf: Date()) {
            return .ok(snapshot)
        }
    } catch {
        Log.provider.error("grok billing failed: \(error.localizedDescription, privacy: .public)")
    }
    if let fallback = Self.logSnapshot() { return .stale(fallback, asOf: fallback.asOf) }
    return .unavailable
}
```

Note the shape: try the live source, fall back to a local one, and only then give
up. A provider with no fallback simply skips the middle step.

### Building the snapshot

```swift
UsageSnapshot(
    primary: primary,      // the ring — pick the window the user is about to hit
    windows: windows,      // popover rows, primary first
    asOf: Date(),
    detail: "Pro plan"     // footer: plan or tier, or nil
)
```

`UsageWindow(label:percentUsed:resetsAt:)` clamps its percentage to 0…100 in the
initializer, so a server that reports 103% cannot overflow a ring.

Choose the ring window carefully: it should be **the limit that will bite
first**, which is almost always the short rolling window rather than a weekly
total. Claude's provider is explicit about this — it uses `five_hour`, falls back
to the `session` entry, and returns `nil` rather than substituting a weekly
number that would read as reassuring when it isn't.

## Step 3 — decoding without brittleness

These are all private, undocumented APIs. They will change shape without notice,
and the app's job is to degrade to `–` rather than crash. Use `JSONValue`, the
optional-tolerant reader in `Provider.swift`:

```swift
let percent = root["rate_limit"]["primary_window"]["used_percent"].double  // Double?
let resets  = root["rate_limit"]["primary_window"]["reset_at"].epochDate   // Date?
let iso     = root["five_hour"]["resets_at"].isoDate                       // Date?
for entry in root["additional_rate_limits"].array { … }                    // never nil
```

Every accessor returns an optional or an empty collection. Subscripting a missing
key is fine; subscripting a string as if it were an object is fine. Nothing
throws.

**Guard against silent zeroes.** Proto3 JSON omits fields at their default
value, so an absent `creditUsagePercent` genuinely means 0 — but an absent
*everything* means the schema moved. `GrokProvider` checks that at least one
known field is present before trusting a reading:

```swift
let knownFields = ["creditUsagePercent", "currentPeriod", "productUsage",
                   "subscriptionTier", "onDemandCap", "onDemandUsed"]
guard knownFields.contains(where: { config[$0].exists }) else { return nil }
let percent = config["creditUsagePercent"].double ?? 0
```

## Step 4 — a glyph

Add a case to `ProviderGlyph` and a `Shape` in `Glyphs.swift`. Glyphs are
`Path`-drawn, not assets — the app ships with no resources at all. Draw inside a
unit square; `GlyphView` handles scaling and color. Keep it legible at 16pt: a
silhouette, not a logo.

## Step 5 — the registry line

```swift
enum ProviderRegistry {
    static let all: [any UsageProvider] = [
        ClaudeProvider(),
        CodexProvider(),
        GrokProvider(),
        YourProvider(),   // ← here
    ]
}
```

Rings render in this order.

## Optional: watching files

If your harness writes a file when usage changes, implement `start()` to get an
immediate poll instead of waiting out the interval. Codex does this:

```swift
func start(onExternalChange: @escaping @Sendable () -> Void) async {
    guard watcher == nil else { return }
    let watcher = FSEventsWatcher(path: Self.sessionsPath, latency: 2.0, onChange: onExternalChange)
    watcher.start()
    self.watcher = watcher
}
```

`start()` is called once by the model after the registry is built — **never do
this in `init`**, which runs before the app has a run loop.

`FSEventsWatcher` already handles the awkward parts: the C callback bridge, the
dispatch queue, and `kFSEventStreamCreateFlagFileEvents`, which is mandatory
when the files you care about are nested below the watched directory. A plain
`DispatchSource` on a directory never sees writes to files three levels down.

### Tailing large logs

Use `Usage.tailLines(path:byteCount:)`. It reads only the final N bytes, discards
the inevitably-partial first line, and hands back complete lines. Scan them in
reverse for the newest usable record:

```swift
let lines = Usage.tailLines(path: path, byteCount: 256 * 1024)
for line in lines.reversed() {
    guard line.contains("token_count") else { continue }   // cheap pre-filter
    …
}
```

The `contains` check before parsing matters: a 256KB tail is a few thousand
lines, and JSON-parsing all of them on every poll is waste you can skip.

## Step 6 — verify

```sh
swift build && swift run Tachyon --smoke
```

The diagnostic runs every provider once and prints presence, the ring window,
each popover row with its formatted reset time, and the plan string. Check that:

- Signed out → `.notSignedIn` with actionable guidance, not a crash
- Signed in → a plausible ring percentage matching your harness's own `/usage`
- Reset times are formatted, not epoch numbers (a wrong unit is obvious here)
- Killing the network gives `–` or a stale reading, never a hang

Then run the app and confirm the ring appears, hover shows your rows, and the
percentages match what your harness reports.

## House rules

- **No third-party dependencies.** URLSession, Security, CoreServices,
  ServiceManagement. That is the whole toolbox.
- **No force-unwraps on external data.** A server response is not a promise.
- **`os.Logger` for logging**, subsystem `dev.gonzih.tachyon`. The `Log` enum in
  `Provider.swift` has the categories.
- **No token refresh in v1.** Refresh tokens rotate single-use; racing the
  harness for them breaks the user's sign-in. Expired token → `.authError` with
  the command that fixes it.
- **Never log a token**, not even truncated, not even at debug level.
- **Keychain reads shell out to `/usr/bin/security`.** This looks like a
  workaround and is in fact the point: the "Always Allow" ACL binds to the
  requesting binary's signature, and an ad-hoc-signed app gets a new one on
  every build. Apple's `security` binary is stable, so the user is prompted
  once and never again.
- **Comment the non-obvious.** Every strange line above exists because something
  otherwise breaks; say which thing, so the next contributor doesn't "clean it
  up".

## Deferred provider slots

`kb/RESEARCH.md` records researched-but-unimplemented mechanics for Gemini CLI,
GitHub Copilot, Cursor, and Hermes/Nous — endpoints, credential locations, and
the known sharp edges for each. If you want a starting point, start there.
