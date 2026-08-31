# Contributing a provider

> **If you are a coding agent:** this document is your task spec, and
> [AGENTS.md](AGENTS.md) is the operating manual for this repository — read
> both before touching anything. AGENTS.md covers the build/test loop, repo
> layout, release process, and the hard rules (authority, credentials,
> honesty); it is as binding as anything here. Implement one
> file conforming to `UsageProvider`, register it, add a glyph, prove it with
> `swift run Tachyon --smoke`, open a PR titled `provider: <name>`. Everything
> you need is below. **Never leak credentials** — no tokens, account ids, or
> emails in code, fixtures, logs, or the PR; see prompts/add-provider.md.

Adding a provider to Tachyon is **one file, one registry line, one glyph**. The
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
the top). Re-saving the same non-empty secret is intentionally a no-op, so its
revision and any credential-scoped baseline stay intact. Optional protocol
blocks:

- **`about`** — one line shown on hover in the menu and in the Settings pane.
  Skip it when the name says everything (Claude, Codex); use it when it
  doesn't (a corporate account, an aggregator, a proxy).
- **`watchPaths` + `fileChanged(_:)`** — declare files/directories and the app
  owns the FSEvents machinery: watching runs only while your provider is
  enabled, `fileChanged` receives the triggering path (invalidate caches
  there), and a fresh `snapshot()` follows automatically. See `CodexProvider`.
- **`sourceLabel` + `reading()`** — use a source label when one product has
  independent surfaces such as Code, CLI, and Desktop. Override the
  default identity-less `reading()` whenever the scheduler must enforce an
  account boundary. Return the state plus an
  ephemeral opaque fingerprint derived from the exact credential/session
  material that produced it. A fingerprint exists only to blank that source's
  old reading on an account switch; Tachyon never merges sources. Unknown
  identity stays nil. Never use or display email, and never return a raw
  identifier.
- **`shouldRefresh(changedPaths:)`** — reject unrelated FSEvents before parsing
  when the only watchable path is a shared parent directory.

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
    nonisolated var shortName: String { get }      // defaulted to displayName
    nonisolated var sourceLabel: String? { get }   // defaulted to nil
    nonisolated var glyph: ProviderGlyph { get }
    nonisolated var pollInterval: TimeInterval { get }
    nonisolated var isExperimental: Bool { get }   // defaulted to false
    nonisolated var about: String? { get }         // defaulted to nil
    nonisolated var settings: [ProviderSetting] { get }  // defaulted to []
    nonisolated var watchPaths: [String] { get }   // defaulted to []

    func detect() async -> ProviderPresence
    func snapshot() async -> ProviderState
    func reading() async -> ProviderReading        // default: snapshot + nil identity
    nonisolated func shouldRefresh(changedPaths: [String]) -> Bool // default true
    func fileChanged(_ path: String) async         // defaulted to a no-op
}
```

Two required methods. `detect()` answers *should this harness appear at all*;
`snapshot()` answers *what are the numbers right now*.

Any source that needs a hard credential/account boundary overrides `reading()`.
Its `ProviderReading.state`
and `accountFingerprint` must be one coherent observation; never fetch the
state, yield to a possible account switch, and then fingerprint a newly loaded
credential. Check cancellation after awaited credential/file/network work
before mutating caches or last-good state.

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
| `.notInstalled` | No trace of the harness | No ring or Settings pane; checked, toggleable menu row shows “not installed” |
| `.notSignedIn(guidance)` | Harness present, no usable credential | No ring; checked, toggleable menu row and Settings show your guidance |
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
| `.ok(snapshot)` | Current numbers from a live response or freshly emitted provider observation |
| `.stale(snapshot, asOf:)` | Real numbers from a fallback or an older read |
| `.authError(guidance)` | Authentication specifically — nothing else |
| `.unavailable` | Everything else: network down, schema drift, missing file |

The model expires unchanged `.stale` data after three provider poll intervals,
on a local deadline independent of network backoff. Set `asOf` to the real
source timestamp; never stamp an old record as newly fresh. Once that timestamp
expires, returning the identical record again stays unavailable instead of
starting a new grace period. If a current `.ok` reading later becomes
unavailable, its fallback deadline is likewise anchored to the snapshot's
`asOf`, not to a delayed failure discovered after sleep.

That last distinction is a rule, not a preference. `.authError` renders a `!`
badge that tells the user to go run a command; if you return it for a network
blip you have sent them on a pointless errand. Network failures, decode
failures, and missing files are all `.unavailable`, which renders `–`.

```swift
func snapshot() async -> ProviderState {
    guard let account = Self.loadAccount() else {
        if let fallback = Self.logSnapshot() { // decoder enforces a short TTL
            return .stale(fallback, asOf: fallback.asOf)
        }
        return .authError(Self.authGuidance)
    }
    do {
        let result = try await Usage.get(Self.billingURL, headers: headers)
        if result.status == 401 || result.status == 403 {
            return .authError(Self.authGuidance)
        }
        if (200..<300).contains(result.status),
           let snapshot = Self.decodeBilling(JSONValue.parse(result.body)["config"], asOf: Date()) {
            return .ok(snapshot)
        }
    } catch {
        Log.provider.error("grok billing request failed")
    }
    return .unavailable
}
```

This example's log records carry no account identifier, so they are short-lived
signed-out history only. Never attach an unbound file/log fallback to an
authenticated credential: after an account switch, it may belong to the prior
login. An authenticated fallback is valid only when it proves the same account
or is queried with the exact credential that produced the live reading.

### Building the snapshot

```swift
UsageSnapshot(
    primary: primary,      // the ring — pick the window the user is about to hit
    windows: windows,      // popover rows, primary first
    asOf: Date(),
    detail: "Pro plan"     // footer: plan or tier, or nil
)
```

`UsageWindow(label:percentUsed:resetsAt:windowSeconds:)` clamps its percentage
to 0…100 in the initializer, so a server that reports 103% cannot overflow a
ring.

### The ring rule — worst active bounded window (aim here)

**Every provider must aim at this.** The user is hard-blocked the moment *any*
independent limit hits 100%, so the ring must show the window **closest to
blocking them** — never a window that happens to look reassuring. A weekly at
70% outranks a session at 10%: the session resets in hours, the weekly is the
wall the user is actually walking toward. The goal of the whole app is "drain
every token, know when to switch providers" — the ring is that decision at a
glance.

The recipe, step by step:

1. **Compute each window's percent.** If the API gives you `used` and `limit`,
   it is `used ÷ limit × 100`. Most APIs hand you the percent directly.
2. **Classify each window.** A window is **hard** when it is an independent
   provider limit that can block the user on its own (session, weekly,
   per-model weekly, key limit). A window is **synthetic** when it is a spend
   meter, a budget-derived percent (the user set the ceiling, the provider
   won't enforce it), or a *breakdown* of another pool (a sub-meter that can
   never bite on its own). In code the distinction is mechanical: hard windows
   carry only `percentUsed`; synthetic ones carry `spendUSD`.
3. **Build ALL your windows, then call `windows.worstFirst()`.** It moves the
   highest-percent hard window to index 0 — index 0 is the ring. Synthetic
   windows never outrank a hard one. Do not hand-pick a primary.
4. **Keep every window as a popover row.** The ring answers "how close is the
   nearest wall"; the popover answers "which wall".

Only deviate when the provider's own semantics demand it (OpenRouter's
prepaid credits are the account's true wall, so they lead), and say why in a
comment.

### Pace — burning faster than the clock

A weekly at 70% with five days left is a much worse place than 70% with four
hours left. Tachyon escalates the **color** (never the number) one band when a
window is on pace to exhaust before it resets. The math, so any agent can
reproduce it:

```
elapsed_fraction = 1 − (reset_at − now) ÷ window_duration
projected_at_reset = percent_used ÷ elapsed_fraction
```

If `elapsed_fraction ≥ 0.1` (earlier projections are wild) and
`projected_at_reset ≥ 100` — the user runs out before the reset at the current
burn rate — the color lifts to the next band's floor: green→yellow,
yellow→orange, orange→red. One band, never more: pace is a warning, not a
measurement. Provider-enforced pace-hot windows also *pulse* (ring, shim,
popover bar). A hard window at 100% stays hot: in a multi-account capacity
tool, switching to another pool is still an available decision. A
user-authored spend budget carries `spendUSD`, so it may use percentage colors
but never pace-escalates, pulses, or says `Limit reached`.

Worked example: a weekly window (`window_duration = 604800`s) that resets in
3.5 days → `elapsed_fraction = 0.5`. At 38% used, `projected = 76` → no
escalation, colors read the raw 38. At 55% used, `projected = 110` → the bar
shows 55% but wears orange instead of yellow.

**Your only job as a provider author is to pass `windowSeconds`** when you
know the duration (5h session = `18000`, weekly = `604800`; Codex hands you
`limit_window_seconds` directly). `PacePresentation` centralizes caption,
band, pulse, and stale suppression for every surface — leave `windowSeconds`
nil and the window simply never pace-escalates.

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
        ClaudeDesktopProvider(),
        CodexProvider(),
        CodexDesktopProvider(),
        GrokProvider(),
        YourProvider(),   // ← here
    ]
}
```

Rings render in this order.

## Optional: watching files

If your harness writes a file when usage changes, declare `watchPaths` to get
an immediate poll instead of waiting out the interval. Codex does this:

```swift
nonisolated var watchPaths: [String] { [Self.sessionsPath, Self.authPath] }
```

The model owns watcher lifecycle, starts it only while enabled, retries paths
that do not exist yet, coalesces duplicate burst paths, and finishes all
accepted `fileChanged` invalidations before firing one fresh snapshot signal.
Watcher work is canceled and detached from model lifetime on disable/stop.
Override `fileChanged` when your provider has cached state to invalidate. Do
not create an FSEvents stream in your provider or in `init`.

`FSEventsWatcher` already handles the awkward parts: the C callback bridge, the
dispatch queue, and `kFSEventStreamCreateFlagFileEvents`, which is mandatory
when the files you care about are nested below the watched directory. A plain
`DispatchSource` on a directory never sees writes to files three levels down.

### Tailing large logs

Use `Usage.tailLines(path:byteCount:)`. It reads only the requested final bytes
(hard maximum 16MiB), preserves the first line when the tail starts on a record
boundary, otherwise discards that partial line, and hands back complete lines.
Scan them in reverse for the newest usable record:

```swift
let lines = Usage.tailLines(path: path, byteCount: 256 * 1024)
for line in lines.reversed() {
    guard line.contains("token_count") else { continue }   // cheap pre-filter
    …
}
```

For small config or credential files, use
`Usage.boundedFile(path:maximumBytes:)`; never call an unbounded whole-file read
on a provider-controlled path. Shared HTTP helpers also reject malformed,
non-ASCII, control-bearing, or oversized header fields before a request starts,
stream response bodies into a strict 4MiB cap, and cancel oversized transfers.

The `contains` check before parsing matters: a 256KB tail is a few thousand
lines, and JSON-parsing all of them on every poll is waste you can skip.

## Step 6 — verify

```sh
brew install fummicc1/tap/swift-complexity   # once
./verify.sh --live
```

The script runs the warning-clean build, full test suite, exact cognitive lint
(`swift-complexity Sources --cognitive-only --threshold 15 --recursive`), and
patch-whitespace check before the live diagnostic. CI runs the same script
without `--live`, because it has no user credentials. The diagnostic runs every
provider once and prints presence, the ring window, each popover row with its
formatted reset time, and the plan string. Check that:

- Signed out → `.notSignedIn` with actionable guidance, not a crash
- Signed in → a plausible ring percentage matching your harness's own `/usage`
- Reset times are formatted, not epoch numbers (a wrong unit is obvious here)
- Killing the network gives `–` or a stale reading, never a hang

Then run the app and confirm the ring appears, hover shows your rows, and the
percentages match what your harness reports.

## House rules

- **No third-party dependencies.** Use Apple/system frameworks and libraries
  already linked by the project (including URLSession, Security, CoreServices,
  ServiceManagement, SQLite3, CommonCrypto, and CryptoKit).
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
GitHub Copilot, and Hermes/Nous, plus the evidence behind integrated providers
such as Cursor. If you want a starting point, start there.
