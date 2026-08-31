# Tachyon — Spec v2

Edge-docked macOS utility for making the most of finite AI coding capacity.
Native Swift, zero-config, provider-extensible. **Install → rings appear →
use the runway well.**

## 1. Product

**Problem:** Heavy harness users need to finish real work inside several finite
session and weekly allowances. They should not have to context-switch to
`/usage` or `/status`, nor discover too late that they burned a window too
quickly. Remaining capacity and burn pace should be ambient, glanceable, and
non-intrusive.

**Form factor:** A black rounded pill docked to the **right screen edge,
vertically centered**, one ring per enabled ready source (glyph, progress ring,
and percent). It self-effaces when windows overlap it, leaving a 5pt color shim;
a full-screen app on that same display hides even the shim. Mousing to the edge
reveals it. Hover a ring → dark detail popover.

**Product decision:** Tachyon is a token-runway instrument, not an alarm panel.
Raw use, projected use at reset, color, and pulse help a user decide whether to
keep going, slow down, or move the next piece of work to another independently
available source. Yellow/orange/red indicate pacing pressure; they are not
judgments that use is bad. Reaching 100% makes switching sources useful, not
panic-worthy.

**Differentiators:** ambient edge UI (not menu-bar dropdown), multi-harness,
truly native (AppKit/SwiftUI, no Electron), first-seen auto-detection,
source-local honesty, and one-file provider contributions.

**Providers:** Claude Code, Claude Desktop, Codex CLI, and Codex Desktop are four
fixed, independent sources. They remain separate even when two surfaces happen
to use the same account or quota pool. Grok and Cursor are experimental; Oh My
Pi, OpenRouter, and Ollama surface activity or spend.

**Glyphs:** official brand marks embedded as SVG path data (simple-icons CC0 + Wikimedia Commons), rendered grayscale via an in-app SVG path parser (`Glyphs.swift`) — no brand colors, no bundled assets.

**Non-goals:** historical charts, exact token accounting, Windows/Linux, App
Store, credential switching/writes, our own OAuth token refresh, cross-source
account merging, and multi-account orchestration.

## 2. Data sources

All mechanics below verified through 2026-08-30 on this machine unless marked
◇; open-source sources and local evidence are recorded in `kb/RESEARCH.md`.

### 2.1 Claude (independent Code and Desktop accounts)

Both sources decode the same subscription windows: `five_hour`, active
`limits[]`, and `seven_day` when `weekly_all` is absent. Every window is built,
then `worstFirst()` selects the ring. No usable window means unavailable.

**Claude Code (`id = "claude"`, source `Code`):**

- Credential priority is `CLAUDE_CODE_OAUTH_TOKEN`, the active Claude Code
  Keychain service, then the active config's `.credentials.json`. Custom
  profiles use `Claude Code-credentials-<first 8 SHA256 hex>` derived from the
  NFC-normalized raw `CLAUDE_SECURESTORAGE_CONFIG_DIR` when present, otherwise
  the non-empty raw `CLAUDE_CONFIG_DIR`; an explicit empty secure-storage value
  selects the unsuffixed service. A custom profile never falls through to an
  unrelated unsuffixed account.
- Keychain access always shells out to `/usr/bin/security`; Tachyon never uses
  `SecItemCopyMatching` for Claude-owned credentials. The cache TTL is 60s so
  a still-valid account switch is noticed. A 401/403 retries the exact original
  source once, never the next credential in the priority chain.
- Usage: `GET https://api.anthropic.com/api/oauth/usage`, bearer auth,
  `anthropic-beta: oauth-2025-04-20`, and the installed Claude CLI user-agent.
  Identity: `GET /api/oauth/profile`; `account.uuid + organization.uuid` are
  immediately HMACed into a per-launch opaque fingerprint and are never
  displayed, logged, or persisted.
- The provider enforces its own credential-scoped request deadline in addition
  to scheduler pacing: no same-token usage request less than 120s after the
  previous attempt, extended to 300s after a `429`. Refresh signals wait
  cancellably rather than punching through the deadline and manufacturing more
  failures. A newly adopted credential bypasses the old token's deadline.
- Last-good data is memory-only and cleared whenever the credential changes.
  A 429 can return it as stale; `UsageModel` enforces the bounded stale TTL.

**Claude Desktop (`id = "claude-desktop"`, source `Desktop`):**

- Resolve the running app by bundle ID `com.anthropic.claudefordesktop`, then
  known system/user installs at `/Applications/Claude.app` and
  `~/Applications/Claude.app`. Search an inherited, non-empty absolute
  `CLAUDE_USER_DATA_DIR` and the default
  `~/Library/Application Support/Claude`, standardized and deduplicated. For
  every root, try both Chromium `Network/Cookies` and legacy `Cookies`
  databases; one readable but signed-out database must not hide a later usable
  candidate. Open SQLite read-only/query-only and read only
  `.claude.ai`/`claude.ai` cookie rows. Read `Claude Safe Storage`
  through `/usr/bin/security`, derive the AES-128 key with PBKDF2-HMAC-SHA1
  (`saltysalt`, 1003 rounds), decrypt `v10`/`v11` AES-CBC values, and for schema
  24+ verify the SHA-256 host binding before stripping it. Crypto failure is a
  normal unavailable state, never a precondition/crash.
- Keep the bounded applicable cookie jar in memory only and send it only to
  HTTPS `claude.ai` using an ephemeral cookie-less `URLSession`. SQLite loading
  isolates up to 64 identity rows from a separately bounded general-cookie set
  (512 rows total); the load fails closed above 64 identity rows, so junk rows
  cannot crowd out the selected account. Each request then accepts at most 128
  safe cookies in a 32KiB header while prioritizing identity cookies. Reject
  conflicting `sessionKey` values at the API, bootstrap, or organization-usage
  scopes and conflicting `lastActiveOrg` values; identity must be unambiguous
  before any request. Reconstruct the installed Claude/Electron Chrome
  user-agent once per app version.
- `GET /api/bootstrap` selects the active chat-capable organization and yields
  the same opaque `account.uuid + organization.uuid` fingerprint. Then
  `GET /api/organizations/{organization}/usage` feeds the shared decoder.
  No cookie, identifier, email, or response body appears in logs/defaults.
- Cache session material for 60s; watch all candidate cookie locations and
  invalidate on relevant writes. On 401/403, reject only that exact session
  material, reload once, and continue to later database candidates; an I/O,
  Keychain, or SQLite failure is unavailable and must not poison the auth
  rejection cache. A canceled load cannot replace the current session/context
  or last-good reading, and last-good data is keyed to the exact selected
  session. Never write cookies, Safe Storage, Claude files, or any credential.

**Separation:** Code and Desktop always retain their own scheduler, setting,
state, ring, and source label. Even a matching verified account/organization
fingerprint never merges them. The fingerprint binds a reading to the exact
source-local credential only, so a later account switch cannot inherit an old
snapshot. A signed-out Desktop source cannot suppress or contaminate a healthy
Code source, and vice versa.

### 2.2 Codex (independent CLI and Desktop sources)

**Codex CLI (`id = "codex"`, source `CLI`)** owns live auth and uses three
read-only streams, in priority order:

- **Stream A (primary, pollable):** `GET https://chatgpt.com/backend-api/wham/usage`
  Headers: `Authorization: Bearer <tokens.access_token>` and, only when non-empty, `ChatGPT-Account-Id: <tokens.account_id>`. A GET sends no synthetic `Content-Type`. Creds come from `$CODEX_HOME/auth.json` (default `~/.codex/auth.json`). A root `chatgpt_base_url` in `config.toml` selects Codex's matching path style: `/wham/usage` under a ChatGPT `backend-api` base, `/api/codex/usage` otherwise. Because this endpoint receives the bearer token, custom bases require HTTPS; plain HTTP is accepted only for explicit `localhost`, IPv4 `127/8`, or `[::1]` loopback development endpoints. Userinfo, query, and fragment components are rejected, and the same validated base is the only one passed to the isolated app-server probe.
  Fields: `plan_type`, `rate_limit.primary_window/secondary_window {used_percent, limit_window_seconds, reset_at(unix)}`, `additional_rate_limits[] {limit_name, rate_limit{...}}`, `credits`, `rate_limit_reached_type`.
  Ring = worst active bounded window across primary/secondary/touched side pools (CONTRIBUTING "The ring rule"). A secondary-only response remains valid. Popover rows: primary + secondary + `additional_rate_limits` entries (labeled by `limit_name`) — but per-model side pools are shown only once any of their windows reaches ≥1% used (untouched pools like "GPT-5.3-Codex-Spark" are noise). Window label derived from `limit_window_seconds`: 18000→"Current session", 604800→"Weekly", else "Nh window".
  Poll: 60s, same backoff as Claude. Tachyon never refreshes Codex OAuth. Plan cross-check: decode `tokens.id_token` JWT claim `https://api.openai.com/auth`.`chatgpt_plan_type` and format known business/education/enterprise variants for display.
- **Stream B (safe best-effort app-server fallback):** after Stream A fails and only when both an access token and account id exist, resolve a Codex executable from the running app/bundle ID, known system and user `Codex.app`/`ChatGPT.app` installs, then the standalone CLI, and launch it as `app-server --stdio`. The child receives a fresh empty `0700` `CODEX_HOME`, analytics disabled, the selected `CODEX_CA_CERTIFICATE` path when set, and no inherited OpenAI/Codex token environment variables. Tachyon initializes with the experimental API capability, installs the existing access token using the experimental process-local `account/login/start` type `chatgptAuthTokens`, then reads `account/rateLimits/read` and optional `account/usage/read`. It never supplies a refresh token, never loads managed auth, and explicitly rejects every server→client `account/chatgptAuthTokens/refresh` request. The JSONL transport has one shared deadline plus per-line and total-output caps; the child is always terminated and its temporary home removed. This API is marked unstable/internal upstream, so any failure falls through without replacing Stream A.
- **Stream C (signed-out CLI history + change signal):** newest `$CODEX_HOME/sessions/YYYY/MM/DD/rollout-*.jsonl`, newest timestamped `payload.type=="token_count"` event with at least one valid `payload.rate_limits.primary/secondary {used_percent, window_minutes, resets_at}` and not attributed to the exact `Codex Desktop` originator. Rollouts carry no account identity, so they are never attached to an authenticated credential. While signed out, only an event no more than 180s old and no more than 60s in the future may remain visible as explicitly stale history. Tail-parse rules: read the last 256KB, iterate lines in reverse, sweep at least the five newest day directories and continue through older directories until five candidate files are found, stop at an independent 2,048-directory safety ceiling, reject ineligible timestamps before comparison so one corrupt future record cannot hide a valid one, and choose the newest eligible event timestamp across those files rather than trusting file mtime. Apply the same worst-window rule and preserve `window_minutes` as the pace duration.
  Watch: **FSEventStream only** (`FSEventStreamCreate` with `kFSEventStreamCreateFlagFileEvents` on `~/.codex/sessions`, 2s latency) — rollout files are 3 directory levels deep; DispatchSource on the root dir never fires for them. The queue-confined watcher forwards accepted paths to `UsageModel`, which deduplicates burst paths, completes cache invalidation, then wakes that source's poll signal once.
- Authenticated reads try Stream A, then the isolated Stream B, and fail closed
  rather than attributing unbound Stream C history to the selected account.
  Signed-out Stream C is freshness-bounded as above. Rollout events still
  trigger an immediate live poll (a completed turn = numbers changed).
- **Codex Desktop (`id = "codex-desktop"`, source `Desktop`):** resolve the
  native Codex app by bundle ID `com.openai.codex` and known system/user
  `Codex.app` or `ChatGPT.app` locations. Read only recent rollout files whose
  `session_meta.payload.originator` is exactly `Codex Desktop`, using the same
  bounded tail parser and restored sparse-history traversal. The source has no
  safe account identity or non-refreshing live credential export, so it never
  reads managed Desktop auth, never calls the live endpoint, never supplies a
  fingerprint, or stamps a file with poll time. An exact-origin observation is
  current for its first 60s, stale from 60s until the shared 180s age ceiling,
  then unavailable; a newer source timestamp restarts that lifecycle. Fresh
  Desktop observations use the same generic pace projection as every other
  current bounded provider window. It remains separate from Codex CLI even when
  both surfaces share a `$CODEX_HOME` or quota pool. A CLI auth failure cannot
  claim Desktop history, and Desktop history cannot suppress the CLI source.

### 2.3 Grok (Grok CLI, xAI) — ◇ experimental until live-verified

- **Creds:** `~/.grok/auth.json` (respect `GROK_HOME`/`GROK_AUTH_JSON`): map of `scopeKey → {key(JWT), refresh_token, auth_mode:"oidc", oidc_issuer, oidc_client_id, email, user_id}`; filter to entries with issuer `https://auth.x.ai`. Access-token expiry from JWT `exp` claim. File absent (as on this machine) → provider state "not signed in".
- **Stream A (primary):** `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits`
  Headers: `Authorization: Bearer <key>`, `X-XAI-Token-Auth: xai-grok-cli`, `x-userid: <user_id>`, `User-Agent: GrokCLI/<version>`.
  Proto3-JSON payload: `config.creditUsagePercent` (**ring**; omitted field = 0
  per proto3 defaults), `config.currentPeriod`, `config.productUsage[]`,
  `onDemandCap/Used`, `subscriptionTier`. Reset time comes from
  `currentPeriod.end`; a valid positive `end − start` supplies the pace
  duration to every window. Never hard-code seven days because xAI periods may
  be weekly or monthly.
- **Stream B (signed-out history):** tail the last 8MB of
  `~/.grok/logs/unified.jsonl`, scan backwards for
  `msg=="billing: fetched credits config"`, and parse the same struct from
  `ctx.config`. Unified logs carry no account identity, so authenticated
  request/auth failures never fall back to them. While signed out, accept only
  a record no more than five minutes old and no more than 60s in the future.
- No OIDC refresh in v1 (single-use rotation risk): expired JWT → auth-error state ("Run `grok` to refresh sign-in").
- Poll: 120s (weekly window moves slowly).

### 2.4 Provider abstraction — the contributor surface

```swift
protocol UsageProvider: Sendable {
    nonisolated var id: String { get }            // scheduler/settings source id
    nonisolated var displayName: String { get }
    nonisolated var shortName: String { get }
    nonisolated var sourceLabel: String? { get }  // "Code", "CLI", "Desktop", or nil
    nonisolated var glyph: ProviderGlyph { get }  // Path-drawn vector
    nonisolated var pollInterval: TimeInterval { get }
    nonisolated var watchPaths: [String] { get }
    func detect() async -> ProviderPresence       // .notInstalled / .notSignedIn / .ready
    func snapshot() async -> ProviderState        // .ok(UsageSnapshot) / .stale(UsageSnapshot, asOf) / .authError(guidance) / .unavailable
    func reading() async -> ProviderReading       // default snapshot + nil identity; verified sources bind both atomically
    nonisolated func shouldRefresh(changedPaths: [String]) -> Bool
    func fileChanged(_ path: String) async
}
struct UsageSnapshot: Sendable {
    let primary: UsageWindow            // ring
    let windows: [UsageWindow]          // popover rows (primary first)
    let asOf: Date
    let detail: String?                 // "Max", "Pro plan", tier…
}
struct UsageWindow: Sendable {
    let label: String
    let percentUsed: Double?            // clamped 0…100 at provider boundary
    let spendUSD: Double?
    let count: Int?
    let resetsAt: Date?
    let windowSeconds: Double?
}
```
- Registry: static array of source providers. A source with an existing enabled
  preference obeys that choice. A first-seen source with no preference gets one
  read-only detection pass: persist enabled only for `.ready`, otherwise
  persist disabled for `.notInstalled`/`.notSignedIn`. This classification is
  per provider ID, so a source added in a later app version is detected once
  without revisiting older choices. Disabled sources then perform no
  credential, file, network, or watcher work until the user enables them.
  Rings render only for enabled `.ready` sources.
- Every source retains its own scheduler, setting, reading, and ring. No
  fingerprints, account IDs, or apparent shared quota pools merge sources.
  Where available, an opaque per-launch fingerprint is derived from the exact
  credential/account context used for that source's request. It exists only to
  prevent an old source-local account reading from surviving a credential
  switch. Missing identity remains nil.
- Every stale source, including a provider-supplied file/log fallback, expires
  after three poll intervals unless its authoritative `asOf` advances. A local
  expiry task blanks it on that deadline without forcing an early network retry,
  so provider backoff can never extend stale UI data. The model remembers the
  newest expired source timestamp, so returning the identical file/log record
  on later polls cannot re-arm another grace window. When a current `.ok`
  reading later becomes unavailable, fallback age starts at the earlier of its
  real `asOf` and the failure time; sleep or delayed polling cannot make an old
  observation newly fresh.
- Run-generation and per-source epoch guards discard provider results and watch
  callbacks that finish after stop, disable, or rapid disable/re-enable.
  FSEvent invalidations are source-coalesced and task-owned; stop/restart also
  clears old readings, poll timestamps, backoff, and fingerprints before
  revalidation, so a previous account is never presented as live.
- Local configs/credential files have explicit byte ceilings; tail reads are
  request-bounded (and reject byte counts above 16MiB); JWT and header values are
  bounded; and shared HTTP construction rejects non-ASCII/control header bytes
  before any request is sent. Shared HTTP responses stream into a strict 4MiB
  body cap and cancel the transfer immediately when the cap is exceeded.
- **Contributing a provider = one new file** conforming to `UsageProvider` + one registry line + one glyph. `CONTRIBUTING.md` documents this with `GrokProvider.swift` as the worked example. Everyone is welcome; that's the product's flywheel.
- Nonisolated metadata as stored `let`s (Swift 6 strict concurrency: actors can't witness computed sync requirements).
- **Maintenance invariant:** provider implementations are intentionally more
  explicit than ordinary app code. Their branches form a compatibility and
  safety matrix across app versions, install locations, user-data roots,
  credential owners, file schemas, retry classes, and partial payloads found on
  different machines. Cognitive-complexity work may extract and name branches;
  it must not delete discovery candidates or bounded fallbacks, collapse auth
  failures into I/O failures, or optimize down to the maintainer's machine.

### 2.5 Deferred (v1.1+ notes, kb-recorded so contributors can pick up)

- Claude token refresh is intentionally unsupported. Claude Code owns rotating
  credentials; racing or writing them can break the harness. Tachyon only
  adopts newly written credentials on the next bounded cache/file refresh.
- Codex token refresh stays out of scope. In particular, do not launch app-server against the user's managed auth home: current managed `account/rateLimits/read`/`account/usage/read` paths can call the auth manager and proactively refresh. Only the isolated external-token probe in §2.2 is permitted.
- Claude statusline-bridge stream (Limits' trick ◇): hook `~/.claude/settings.json` statusLine to capture live windows with zero token handling. Powerful but mutates user config — opt-in only, never default (violates "non-intrusive").
- Gemini CLI ◇: `POST https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota` (bearer from `~/.gemini/oauth_creds.json`, preceded by `:loadCodeAssist` for tier/projectId); refresh needs Google's non-public client secret — converged hack regexes `OAUTH_CLIENT_ID/SECRET` out of installed gemini-cli JS. Fragile; contributor slot.
- Copilot ◇: `GET https://api.github.com/copilot_internal/user` with GitHub OAuth token (VS Code device-flow client `Iv1.b507a08c87ecfe98`). Contributor slot.
- ~~Cursor on hold~~ **Integrated 2026-08-28**: `CursorProvider.swift` —
  read-only SQLite of `state.vscdb` (`cursorAuth/accessToken` and membership;
  email is deliberately not read), CLI fallback `~/.cursor/auth.json`; `POST
  api2.cursor.sh/.../GetCurrentPeriodUsage` (Connect protocol); ring =
  `planUsage.totalPercentUsed`, rows for auto/API meters ≥1% + spend limit.
  `billingCycleStart/End` accept ISO, epoch seconds, or epoch milliseconds; a
  positive `end − start` is propagated to every row for generic pace text.

## 3. UI spec

### 3.0 Presence model (docked / shim / suppressed → revealed)

Pill is **vertically centered on the right screen edge**, with four explicit
presentation states:

1. **Docked (default):** fully visible, flush to edge. Active whenever no window overlaps its frame.
2. **Shim (auto-hidden):** any normal window overlapping the pill frame → pill slides off-edge (0.25s ease-out) leaving a **5pt-wide color shim**: one vertically-stacked rounded segment per enabled provider, filled with that provider's usage color (§3.1 bands), 60% opacity, 2pt gaps, total height = pill height. A warm sliver keeps pace pressure glanceable; otherwise it stays visually silent.
3. **Suppressed (full screen):** a foreign window matching the full frame of
   Tachyon's chosen display → pill and color shim are both absent while idle.
   Fullscreen on another display has no effect. The same invisible 12pt edge
   band remains armed, so the UI is recoverable without a permanent mark over
   native full-screen work.
4. **Revealed (hover):** pointer entering the 12pt-wide edge hot zone spanning
   the pill's band (dwell 150ms, global `mouseMoved` monitor) slides the pill out
   **over** the covering window. It stays while the pointer is inside
   pill∪popover; an already active hover or pinned popover is never removed by a
   new fullscreen observation. After interaction ends, it collapses to Shim,
   Suppressed, or Docked from a fresh synchronous reading.

- Window detection: `CGWindowListCopyWindowInfo(.optionOnScreenOnly)` at 1s
  cadence + refresh on `NSWorkspace` app-activation and space-change
  notifications. Filter to visible, nontransparent layer-0 windows on the
  chosen display and exclude Tachyon's PID. A full-screen classification
  matches only `screen.frame` with 2pt tolerance for WindowServer rounding.
  `visibleFrame` is ordinary maximized-window geometry: it must remain Shim so
  a terminal or editor that fills its usable desktop still leaves a useful
  edge signal. Exact per-edge matching keeps spanning and materially inset
  windows in ordinary overlap behavior. Fullscreen outranks overlap when
  several windows are present.
  Geometry is converted through the primary screen's coordinate space so
  negative-origin and mixed display layouts work. Frames/layer/alpha/PID need
  no permission; Tachyon never reads window titles, contents, owner identity,
  or pixels. Hysteresis is 300ms to prevent flapping.
- **No Accessibility or Screen Recording request:** public AX APIs provide
  window position/size and a fullscreen-button element, not a portable foreign
  window fullscreen state. They would add a broad user consent prompt without
  improving this geometry decision. Developer ID signing would stabilize a
  grant across releases but never grants it automatically; ad-hoc dev rebuilds
  would also churn that privacy identity. Keep this feature permission-free.
- All panels at `level = .statusBar` so Revealed renders above normal windows.

### 3.0.1 Regression audit — 2026-08-30

- **R1 — confirmed and fixed in code/tests:** treating `visibleFrame` as
  full-screen suppressed Tachyon behind an ordinary maximized terminal. The
  classifier and its regression tests now require `screen.frame` for
  Suppressed; maximized frames, including side/bottom Dock layouts, produce
  Shim.
- **R2 — reported, cause not yet claimed:** after a Mission Control /
  three-finger Space switch, the overlay was absent on another Space. The
  panels already request `.canJoinAllSpaces`, `.canJoinAllApplications`,
  `.stationary`, and `.fullScreenAuxiliary`; the controller also re-reads,
  repositions, and orders panels on the active-Space notification. R1 can
  mimic this symptom whenever the destination Space has a maximized window,
  so validate R2 only after R1 is manually cleared. Do not call this fixed
  without that independent reproduction.
- **R3 — confirmed policy mismatch:** Codex CLI's decoder paths preserve a
  real weekly duration and reset, while the visible 13%-used row had no pace
  caption near the start of a new week. The shared 10%-elapsed gate is the
  code path that hides that otherwise eligible early warning. A significant
  early burn now shows the qualitative limit warning; stable color/pulse
  behavior still waits for the calendar sample below.

Freshness wording is deliberately quieter than the scheduler state for the two
Claude surfaces. Their usage endpoints are shared with Claude itself and can
return `429` during active work. The first failed refresh immediately becomes
stale internally: it counts toward backoff and disables pace captions, pace
color escalation, and pulse. The visible `stale`/`as of` treatment waits through
one missed 120s poll and appears at 240s since the last verified response. The
existing three-poll bound still blanks the reading to `–` at 360s. Local Claude
activity files prove that work occurred but do not contain subscription-window
utilization, so they never refresh or estimate the percentage.

### 3.1 Pill

- Borderless non-activating `NSPanel`, styleMask `[.borderless,
  .nonactivatingPanel]`; every pill/shim/popover uses the same
  `collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications,
  .stationary, .fullScreenAuxiliary]`. The flags are intentionally distinct:
  follow every user Space, join other apps' window sets/fullscreen Spaces, stay
  stationary in Mission Control, and permit intentional edge-hover reveal over
  fullscreen. On every active-Space change the controller forces a fresh
  obstruction reading, frame placement, and panel ordering even when the
  obstruction value itself did not change. Transparent background;
  `NSApp.setActivationPolicy(.accessory)` is set unconditionally in code (so
  `swift run` behaves like the bundle; `LSUIElement` in the plist is
  belt-and-braces).
- Geometry: right edge, `midY = screen.visibleFrame.midY`. Black `#000` capsule, left corner radius 24pt, right side flat to edge, top/bottom taper via 24pt-radius concave curves (per Figma). Width 64pt.
- Module (per visible source): ring 36pt outer Ø, 3.5pt stroke, clean provider
  glyph centered (white ~16pt), and no source letter, count, or replacement
  badge inside or beside the ring. Percent label beneath (SF Pro 13pt semibold
  white, rounded to int). Module height 56pt, spacing 18pt, pill padding 16pt
  top/bottom; content-driven. Source identity belongs in the popover, Settings,
  context menu, and accessibility label—not in the scarce pill pixels.
- Ring: track white 20%; arc from 12 o'clock clockwise = percentUsed; animate arc+color 0.4s ease-out; numbers cross-fade.
- **Usage colors (half-open bands):** `[0,50)` green #30D158 · `[50,70)` yellow #FFD60A · `[70,90)` orange #FF9F0A · `[90,100]` red #FF453A. (Mock check: 21 green, 52 yellow, 73 orange, ≥90 red.)
- **Pace escalation:** when a fresh provider-enforced percent window with a known
  duration is on pace to exhaust before its reset (`percent ÷
  elapsed_fraction ≥ 100`, after ≥10% of the window has elapsed), its **color**
  lifts one band (green→yellow→orange→red floor); displayed numbers stay raw.
  Applies to ring, shim, and popover bars (`UsageWindow.bandPercent`).
  User-authored spend budgets are planning aids, not provider walls: they use
  normal percentage colors but never pace-escalate.
- **Early runway cue:** before the stable 10%-elapsed sample, a real provider
  window that has already used ≥10% of its quota and projects past 100% shows
  `At this pace, limit before reset` in the popover. It is text only: no band
  lift or pulse. This catches a meaningful early burn without turning a tiny
  first request into blinking urgency.
- Color is decision support for preserving usable runway: green means the user
  can keep working at the current rate, warmer bands invite a pace check, and
  red/100% can suggest slowing down or moving the next task to another enabled
  source. Do not rewrite this as generic danger or consumption-shaming UI.
- **Pace pulse:** a fresh pace-hot ring window additionally *breathes* — the pill
  arc and provider shim oscillate opacity (0.9s ease, autoreversing). A window
  at 100% remains hot because moving work to another source is still a useful
  capacity decision. Spend-budget windows never pulse. Suppressed under Reduce
  Motion; shim animation stays on the render server.
- **Home screen:** the pill lives on the menu-picked display, else the primary
  display (`NSScreen.screens.first`) — never `NSScreen.main`, which follows
  keyboard focus and desynchronizes the presence machine from the pill's frame.
- States: before first snapshot & `.unavailable` → track-only ring, "–" label,
  50% opacity. `.authError` → dimmed ring with "!" badge. `.stale` preserves
  the raw value and raw percentage color at immediately reduced opacity
  (including the shim), but suppresses pace projection text, band escalation,
  and every blink/pulse. Menu/Settings label it stale, the popover shows “as
  of…”, and the model removes it after the bounded grace period if its source
  timestamp does not advance. The compact status item excludes stale readings
  because it has no room for a qualifier.
- Hit-testing: pill panel accepts events in its rect (concave corner slivers are ~pt² — accepted for v1, noted). Hover/click tracking via **AppKit `NSTrackingArea` `[.activeAlways, .mouseEnteredAndExited, .mouseMoved]`** on a wrapper NSView piped into the model — SwiftUI `.onHover` does not fire in non-activating accessory panels. `acceptsFirstMouse` → true (subclass hosting view) so first click acts.

### 3.2 Popover

- Own borderless panel (not NSPopover): black HUD, corner radius 14, right-pointing tail, width 300pt, positioned left of the pill, vertically centered on the hovered ring then clamped to `screen.visibleFrame`; tail slides along the popover edge to keep pointing at the ring.
- Open: hover ring 300ms (click cancels timer, opens immediately). Exactly one popover instance; hovering another ring retargets content+tail without re-delay.
- Dismiss: hover-opened → pointer exits pill∪popover union +200ms grace. Click-opened → pinned; dismiss on click-away, Esc, or second click on same ring. Esc & click-away via local+global `NSEvent` monitors (borderless panels can't become key; responder-chain keyDown won't arrive).
- Header: glyph + provider name + compact inline source tag (`Code`, `CLI`, or
  `Desktop`) when applicable. This is the unambiguous home for source identity;
  sources are never combined into a `Code + Desktop` row.
- Row per `UsageWindow`: label + provider-reported reset text; 4pt rounded bar;
  raw percent/spend/count caption. After a stable pace sample, show either
  `At this pace, ~N% by reset`, `At this pace, limit before reset`, or
  `Limit reached` for provider-enforced percent windows; a ≥10%-used early
  limit-risk may show the qualitative limit wording alone. A user-authored
  spend budget never receives hard-limit wording. Never fabricate a reset or
  projection without duration.
- Reset formatting: nil → omit; past → "resetting…" (keep last percent until next poll); `<90min` → "Resets in N min"; same-day → "Resets at h:mm a"; else "Resets Thu 12:00 AM".
- Footer (10pt white 40%): freshness ("as of 2m ago" for stale/file-based) + plan/tier.
- Compact layout: 10pt outer stack spacing, 8pt between rows, 12pt vertical /
  14pt horizontal padding, and 3pt inside each row. Preserve the established
  hover/click/pin behavior while reclaiming vertical pixels.

### 3.3 Chrome & settings

- No Dock icon. Minimal theme-adaptive colored ring gauge: fill/color uses
  the closest hard percentage wall across visible sources (never an average of
  unrelated quotas); source-scoped toggles, Launch at Login,
  display picker, Refresh now, diagnostic guidance, Quit.
- Zero providers enabled/ready → hide pill+shim entirely; status item is the way back.
- "Refresh now" wakes enabled ready sources and resets backoff; it never
  extends the TTL of an unchanged stale fallback.
- Launch at Login: `SMAppService.mainApp`; gate the toggle on running-from-bundle; surface `.status` (e.g. `.requiresApproval`) in the menu; README documents `~/Applications` install as supported path (ad-hoc rebuilds invalidate registrations from build dirs).
- Display picker: persist display ID; on disconnect fall back to main screen; auto-return when it reappears (`didChangeScreenParametersNotification`, which also re-centers on resolution change).
- Persistence: `UserDefaults`.

## 4. Architecture & build

- Swift 6.2, macOS 15+ target. AppKit shell + SwiftUI via
  `NSHostingView`; zero third-party dependencies (Apple/system URLSession,
  Security, CoreServices/FSEvents, SQLite3, CommonCrypto, CryptoKit, and
  ServiceManagement only).
- Pure SwiftPM: executable target `Tachyon`; `build.sh` produces `Tachyon.app`
  (binary + generated Info.plist with `LSUIElement`, ad-hoc codesign).
  `verify.sh` is the single deterministic local/CI gate: warning-clean release
  build, full tests, exact cognitive lint
  (`swift-complexity Sources --cognitive-only --threshold 15 --recursive`), and
  patch whitespace. `--live` adds provider smoke; `release.sh` requires that
  live gate before any signing/notarization work.
- Structure:
  ```
  Sources/Tachyon/
    App.swift                     — main, activation policy, AppDelegate, status item
    Presence/OverlapMonitor.swift — CGWindowList polling + hysteresis
    Presence/EdgeController.swift — docked/shim/suppressed/revealed, mouse monitors
    Panels/PillPanel.swift        — NSPanel + tracking-area wrapper view
    Panels/ShimPanel.swift
    Panels/PopoverPanel.swift
    Views/PillView.swift          — SwiftUI rings
    Views/DetailView.swift        — popover content
    Model/UsageModel.swift        — @MainActor @Observable store, scheduler, backoff
    Providers/Provider.swift      — protocol + shared types + registry
    Providers/ClaudeProvider.swift
    Providers/ClaudeDesktopProvider.swift
    Providers/CodexProvider.swift
    Providers/CodexDesktopProvider.swift
    Providers/CodexAppServerProbe.swift
    Providers/GrokProvider.swift
    Providers/FSEventsWatcher.swift
    Glyphs.swift                  — Path-drawn provider glyphs
  build.sh
  verify.sh                     — local/CI/release green gate
  CONTRIBUTING.md                 — "add your harness in one file" guide
  README.md
  ```
- Concurrency: providers are actors (metadata as `let`s); model `@MainActor`;
  FSEvents callback (C fn ptr) bridged via `Unmanaged` in the watcher class,
  then source-coalesced into one owned invalidation task and poll signal.
- Logging: `os.Logger` subsystem `dev.gonzih.tachyon`; secrets and raw account,
  organization, cookie, email, response-body, and session data are never public.

## 5. Risks

| Risk | Handling |
|---|---|
| Keychain prompts on first Claude source reads | Code and Desktop own different items; both go through `security` so “Always Allow” survives rebuilds. |
| Private endpoint/schema drift | Strict bounded decoders → “–”; fallbacks remain stale/TTL-bound; never crash. |
| Two product surfaces share or differ in account | Always keep source IDs and rings separate; never infer a merge or orchestrate accounts. |
| Codex Desktop rollouts have no account identity | Accept only exact Desktop-origin bounded history; current for 60s, stale until 180s, then unavailable; never attach managed auth or a CLI fingerprint. |
| One local install/layout differs from another | Preserve the ordered discovery and schema compatibility matrix; a readable empty candidate never masks a later usable one. |
| Grok mechanics unverified on authed machine | Ships experimental-flagged; state machine handles absence gracefully; verification = first contributor task. |
| Rollout files huge | 256KB tail reads only. |
| Overlap poll cost | 1Hz CGWindowList on one display ≈ negligible; stop polling entirely while Revealed. |
| Fullscreen apps and Spaces | Same-display native full-frame geometry suppresses pill+shim while idle; ordinary maximized usable-frame windows retain the shim. Cross-Space presence remains a manual acceptance check after every panel-policy change; other displays are ignored. |
| Ad-hoc signing + SMAppService | Gated + documented (§3.3). |

## 6. Acceptance criteria (v1 done =)

1. `./verify.sh` passes the warning-clean release build, full tests, cognitive
   threshold 15, and whitespace checks; CI invokes it. `./verify.sh --live`
   reports sane provider state and is enforced before `release.sh` signs
   anything. `./build.sh` from a clean checkout produces `Tachyon.app`.
2. On first launch, each first-seen source performs one read-only detection;
   ready sources persist enabled and unavailable/signed-out sources persist
   disabled without changing any previously stored user choice.
3. Launch on this machine → pill docked right-center; Claude Code, Claude
   Desktop, Codex CLI, and Codex Desktop each retain independent state and
   rings. Matching identity or quota never merges them, and no pill ring has a
   `C`/`D`/source badge.
4. Drag a normal window over the pill → color shim ≤1.5s. Make a foreign
   window full screen on Tachyon's display → pill+shim disappear while idle;
   fullscreen on another display does nothing. Mouse to Tachyon's invisible
   edge band → reveal; an active hover/pin stays visible; mouse away or close
   the pin → collapse to the latest Docked/Shim/Suppressed state.
5. Hover ring → compact popover with correct source tag, rows, pace language,
   and reset formatting; click pins; Esc dismisses.
6. Kill network → rings go "–"/stale per state rules, no crash; restore → recovery on next poll.
7. Run a Codex CLI or Desktop turn → only its matching source accepts the
   rollout origin and wakes/updates within the bounded FSEvents path.
8. Grok (unauthed here) → invisible in pill; unchecked, toggleable menu row shows "sign in" guidance.
9. Quit via status item; launch-at-login toggle works from `~/Applications` install.
10. Idle CPU <0.5% average over 60s in Activity Monitor.

## 7. Milestones

- M1: SPM skeleton, activation policy, pill panel docked right-center, static rings.
- M2: Provider protocol + registry + Claude live end-to-end.
- M3: Independent Codex CLI/Desktop sources + Grok (experimental) + detection states.
- M4: Presence model (overlap → shim → reveal) + popover + polish.
- M5: Status item, launch-at-login, build.sh, README + CONTRIBUTING.md.

## 8. Provider settings & budgets (v1.3)

**Discipline:** the app as a whole remains functional without opening Settings.
Refinement settings have working defaults; a provider whose only data source is
a user-supplied credential may explicitly require a `.secret` setting before
that provider becomes ready (OpenRouter is the current example).

### 8.1 Declarative contract

`UsageProvider` gains one defaulted member — the one-file contributor contract
is preserved (declare in the same file, no UI code):

```swift
nonisolated var settings: [ProviderSetting] { get }   // default []

struct ProviderSetting: Sendable, Identifiable {
    let key: String          // namespaced under "provider.<id>.<key>"
    let title: String
    let help: String?
    let kind: Kind

    enum Kind: Sendable {
        case secret(placeholder: String)          // app Keychain
        case money(defaultValue: Double?)         // USD; nil = "not set"
        case toggle(defaultValue: Bool)
        case choice(options: [String], defaultValue: String)
    }
}
```

- Non-secret values persist in UserDefaults as `provider.<id>.<key>`; secrets
  use Tachyon's Keychain service and never enter UserDefaults.
- A real secret change increments a non-secret revision used to invalidate
  provider-local state and baselines. Saving the same non-empty value is a
  no-op: it performs no Keychain write and does not bump that revision.
- Providers read money/secrets at snapshot time via `Settings.moneySetting`,
  `Settings.secretSetting`, and `Settings.secretRevision`; declarative
  toggle/choice controls use their namespaced UserDefaults keys. A settings
  change triggers an immediate re-poll of that provider.
- App renders one generic form per provider — consistent look, zero provider
  UI code.

### 8.2 Settings window

- Standard macOS settings-style window, opened from the status menu, the pill
  context menu, or ⌘,. The LSUIElement app activates temporarily while the
  window is shown; the pill itself has no gear affordance.
- Left sidebar: **General**, then one row per *detected* provider (glyph +
  source-qualified short name, matching pill visual language). General owns
  Launch at Login and points users to the menu-bar dropdown for the display
  picker and quick provider toggles.
- Right pane: provider status header (presence, last poll, plan) with an
  **Enabled toggle** (same state as the menu checkmarks, `provider.enabled.*`),
  then the declared settings form. Settings-less providers show status +
  toggle — the pane doubles as a diagnostic view.

### 8.3 Budget (first declared setting)

- `OmpProvider` and `OpenRouterProvider` declare `budget.monthly` (`money`,
  default nil).
- Unset → raw spend remains a spend label. OpenRouter account credits or a
  hard key limit still lead when the API reports them.
- Set → spend windows with a monthly period gain
  `percent = spend / budget × 100` → standard color bands and shim color.
  Popover caption: "$34.20 of $50". Because this is a personal planning aid,
  it never pulses or says `Limit reached`.
- Provider-enforced bounded windows from `usage_history`, OpenRouter prepaid
  credits, and hard key limits still outrank budgeted spend for the ring (real
  limits beat synthetic ones).
- Future (not v1.3): auto-baseline (median of last full periods × 1.25) as
  the computed default when unset.

### 8.4 Out of scope v1.3

Per-provider notification thresholds and poll overrides (they become declared
settings later with zero protocol churn); auto-baseline; budget for
non-spend providers.
