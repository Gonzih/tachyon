# Contributing a provider

> **If you are a coding agent:** this document is your task spec. Implement one
> file conforming to `UsageProvider`, register it, add a glyph, prove it with
> `swift run Tachyon --smoke`, open a PR titled `provider: <name>`. Everything
> you need is below. **Never leak credentials** — no tokens, account ids, or
> emails in code, fixtures, logs, or the PR; see prompts/add-harness.md.

Adding a harness to Tachyon is **one file, one registry line, one glyph**. The
app's whole flywheel is that this stays true, so the protocol is deliberately
small and everything hard — polling, backoff, layout, presence, the popover — is
handled for you.

`Sources/Tachyon/Providers/GrokProvider.swift` is the worked example referenced
throughout. Read it alongside this document.

## What a provider can be

A provider is anything that can produce a `UsageSnapshot`. The built-ins cover
the whole palette — copy whichever pattern fits:

| Pattern | Data source | Example |
|---|---|---|
| Local harness, endpoint poll | harness's stored OAuth + its usage API | `ClaudeProvider`, `CodexProvider`, `GrokProvider` |
| Local harness, file read | logs / SQLite the harness already writes | `OmpProvider` (quota + cost), `CursorProvider` (creds via SQLite) |
| Pure config, external API | user-entered key via a `.secret` setting | `OpenRouterProvider` |

And a window can meter anything:

- **Bounded percent** — `UsageWindow(label:percentUsed:resetsAt:)` → colored ring
- **Raw spend** — `UsageWindow(label:spendUSD:resetsAt:)` → "$4.20" readout
- **Spend vs budget** — `UsageWindow(label:spendUSD:budgetUSD:resetsAt:)` →
  percent ring + "$34.20 of $50" caption; wire the budget from a declared
  `.money` setting

Declared settings (`nonisolated let settings: [ProviderSetting]`) render
automatically in the Settings window: `.money` (budgets), `.toggle`,
`.choice`, and `.secret` — the only correct way to take an API key from the
user. Secrets are stored in Tachyon's own Keychain item; **never** put a
credential in UserDefaults, and never print one anywhere (see the hard rule at
the top). Two more blocks:

- **`about`** — one line shown on hover in the menu and in the Settings pane.
  Skip it when the name says everything (Claude, Codex); use it when it
  doesn't (a corporate account, an aggregator, a proxy).
- **`watchPaths` + `fileChanged(_:)`** — declare files/directories and the app
  owns the FSEvents machinery: watching runs only while your provider is
  enabled, `fileChanged` receives the triggering path (invalidate caches
  there), and a fresh `snapshot()` follows automatically. See `CodexProvider`.

Tokens, limits, cost, cost ceilings, external APIs — any combination
works. We can't predict the future; these blocks are meant to be enough that
you don't need us to.

One honesty rule for windows: **`resetsAt` is for provider-reported resets
only.** If your window is a measurement period you invented ("Today",
"This month" over a spend series), pass `nil` — the label already carries the
period, and a fabricated "Resets…" line tells the user a quota refresh exists
when it doesn't.

## The contract

```swift
protocol UsageProvider: Sendable {
    nonisolated var id: String { get }
    nonisolated var displayName: String { get }
    nonisolated var glyph: ProviderGlyph { get }
    nonisolated var pollInterval: TimeInterval { get }
    nonisolated var isExperimental: Bool { get }   // defaulted to false
    nonisolated var about: String? { get }         // defaulted to nil
    nonisolated var settings: [ProviderSetting] { get }  // defaulted to []
    nonisolated var watchPaths: [String] { get }   // defaulted to []

    func detect() async -> ProviderPresence
    func snapshot() async -> ProviderState
    func fileChanged(_ path: String) async         // defaulted to a no-op
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

Glyphs are embedded SVG path data, not image assets — the app ships with zero
resources. In `Glyphs.swift`:

1. Add a case to `ProviderGlyph`.
2. Add its `viewBox` (the coordinate space of your path data).
3. Add its `pathData` — a single SVG `d` string. The built-in parser handles
   M/L/H/V/C/S/Q/T/A/Z, absolute and relative, with implicit repeats. Multiple
   subpaths fill even-odd (use that for knockouts).

**Sourcing the mark, in order of preference:**

1. [simple-icons](https://simpleicons.org) — CC0 path data, already 24×24.
2. [lobehub icons](https://github.com/lobehub/lobe-icons) — MIT, covers most
   AI products.
3. Wikimedia Commons vector logos.
4. Trace the official mark yourself (blocky geometric marks reduce to a short
   hand-written path — see `.omp`).

Rules: the *official* mark, rendered **grayscale only** — `GlyphView` tints it;
never bake brand colors in. Keep it legible at 13–16pt (silhouette, not a
wordmark). Verify by opening the menu and the Settings sidebar.

**Attribution is mandatory.** Add the icon's source and license to all three
attribution surfaces, matching the existing style:

- `README.md` → Credits section ("Provider marks: …")
- `Sources/Tachyon/AboutWindow.swift` → the small-print attribution `Text`
- `docs/index.html` → footer attribution line

If the source is new (not simple-icons/Wikimedia/lobehub already listed), name
it and its license explicitly in all three places.

## Step 5 — tests (required)

Every provider PR must include unit tests, and `swift test` must pass — CI
runs it on every PR. Put them in `Tests/TachyonTests/`, follow the existing
files:

- **Decode/parse coverage is the minimum**: your `decode`/parse function
  against shape fixtures — the happy path, a partial payload, and garbage
  (must return nil, never crash). Fixtures are *shapes with synthetic values*;
  never commit real account data (see the hard rule at the top).
- File-based providers: build a synthetic fixture (temp dir / SQLite) and
  point your provider at it via its env override — `OmpProviderTests` is the
  worked example.
- Any state logic you add (baselines, budgets, freshness rules) gets its own
  tests — `testOpenRouterMonthBaseline` is the pattern.

If it isn't tested, it isn't merged.

## Step 6 — the registry line

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
