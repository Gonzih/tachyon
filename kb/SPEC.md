# Tachyon — Spec v2

Edge-docked macOS utility showing live rate-limit usage for AI coding harnesses. Native Swift, zero-config, provider-extensible. **Install → rings appear → magic.**

## 1. Product

**Problem:** Heavy harness users context-switch constantly to check session windows (`/usage`, `/status`). That info should be ambient, glanceable, non-intrusive.

**Form factor:** A black rounded pill docked to the **right screen edge, vertically centered**, one ring per detected provider (glyph + progress ring + percent). It self-effaces when windows overlap it, leaving a 5pt color shim; mousing to the edge reveals it. Hover a ring → dark detail popover.

**Differentiators:** ambient edge UI (not menu-bar dropdown), multi-harness, truly native (AppKit/SwiftUI, no Electron), zero-config auto-detection, one-file provider contributions.

**v1 providers:** Claude Code (verified live), Codex CLI (verified live), Grok CLI (experimental — mechanics cross-checked against the shipped grok binary's strings; awaiting an authed machine), Cursor (experimental — endpoint verified live via structured Connect 401; awaiting a logged-in machine).

**Glyphs:** official brand marks embedded as SVG path data (simple-icons CC0 + Wikimedia Commons), rendered grayscale via an in-app SVG path parser (`Glyphs.swift`) — no brand colors, no bundled assets.

**Non-goals v1:** cost/dollar analytics, historical charts, token accounting, Windows/Linux, App Store, our own OAuth token refresh (v1.1, see §2.5).

## 2. Data sources

All mechanics below verified 2026-08-28 on this machine unless marked ◇ (from source-dive of 0xNyk/llmquota and AmirTlinov/Limits — see kb/RESEARCH.md).

### 2.1 Claude (Claude Code OAuth)

- **Credential priority:** ① env `CLAUDE_CODE_OAUTH_TOKEN` ② macOS Keychain generic password service `"Claude Code-credentials"` ③ `~/.claude/.credentials.json`. Payload: `claudeAiOauth.{accessToken, refreshToken, expiresAt(ms), subscriptionType, rateLimitTier, scopes}`.
- **Keychain read = shell out to `/usr/bin/security find-generic-password -s "Claude Code-credentials" -w`.** Rationale: the "Always Allow" ACL attaches to Apple's stably-signed `security` binary and survives our rebuilds; `SecItemCopyMatching` from an ad-hoc-signed binary re-prompts after every build. Cache credential in memory; re-read only on 401 or `expiresAt` passed — never unconditionally per poll.
- **Endpoint:** `GET https://api.anthropic.com/api/oauth/usage`
  Headers: `Authorization: Bearer <accessToken>`, `anthropic-beta: oauth-2025-04-20`, `Content-Type: application/json`.
- **Fields consumed:**
  - Windows: `five_hour {utilization%, resets_at ISO8601}` ("Current session"; falls back to `limits[]` entry `kind=="session"`) plus the weekly windows below. **Ring = worst active bounded window** (highest percent across all of them — a weekly at 70% outranks a session at 10%; CONTRIBUTING "The ring rule"). No windows at all → snapshot unavailable.
  - Popover rows: `five_hour` ("Current session") + `limits[]` entries excluding `kind=="session"` and excluding `is_active==false` (label scoped rows with `scope.model.display_name`, e.g. "Weekly (Fable)"); render `seven_day` only when `limits[]` lacks `weekly_all`.
  - `subscriptionType`/`rateLimitTier` → popover footer ("Max").
- **Poll:** 120s (endpoint has its own short-window rate limiter: 429 with `retry-after: 0`, observed live); on wake; on manual refresh. 3 consecutive failures → back off to 5min. Send `User-Agent: claude-cli/<version> (external, cli)` (ecosystem convention). On 401: re-read keychain once and retry immediately in the same cycle; still 401 → **auth-error state**. On 429: return last good snapshot as `.stale` (persisted in UserDefaults so relaunches during a hot throttle window keep numbers on screen); no last-good → unavailable.
- Decode everything optional-tolerant; schema drift → unavailable state, never crash.

### 2.2 Codex (Codex CLI, ChatGPT plan)

Two streams, both live-verified:

- **Stream A (primary, pollable):** `GET https://chatgpt.com/backend-api/wham/usage`
  Headers: `Authorization: Bearer <tokens.access_token>`, `ChatGPT-Account-ID: <tokens.account_id>`, `Content-Type: application/json`. Creds from `~/.codex/auth.json`.
  Fields: `plan_type`, `rate_limit.primary_window/secondary_window {used_percent, limit_window_seconds, reset_at(unix)}`, `additional_rate_limits[] {limit_name, rate_limit{...}}`, `credits`, `rate_limit_reached_type`.
  Ring = worst active bounded window across primary/secondary/touched side pools (CONTRIBUTING "The ring rule"). Popover rows: primary + secondary + `additional_rate_limits` entries (labeled by `limit_name`) — but per-model side pools are shown only once any of their windows reaches ≥1% used (untouched pools like "GPT-5.3-Codex-Spark" are noise). Window label derived from `limit_window_seconds`: 18000→"Current session", 604800→"Weekly", else "Nh window".
  Poll: 60s, same backoff as Claude. No token refresh in v1: 401 → auth-error state ("Run `codex login`"). Plan cross-check ◇: decode `tokens.id_token` JWT claim `https://api.openai.com/auth`.`chatgpt_plan_type`.
- **Stream B (fallback + freshness):** newest `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`, last `payload.type=="token_count"` event with non-null `payload.rate_limits.primary {used_percent, window_minutes, resets_at}`. Used when Stream A unavailable (offline, 401, schema drift). Tail-parse rules: read last 256KB, discard through first `\n`, iterate lines in reverse, take newest match; none found → try next-newest file (up to 5 files).
  Watch: **FSEventStream only** (`FSEventStreamCreate` with `kFSEventStreamCreateFlagFileEvents` on `~/.codex/sessions`, 2s latency) — rollout files are 3 directory levels deep; DispatchSource on the root dir never fires for them. Wrap in a `final class` on a dispatch queue forwarding via `Task { await provider.reload() }`.
- Merge rule: Stream A result wins when fresh; Stream B events also trigger an immediate Stream A poll (a completed turn = numbers changed).
- Note: the ecosystem-converged primary (CodexBar, wakamex/codex-cli-usage) is `codex app-server` JSON-RPC (`codex -s read-only -a never app-server`, methods `initialize`→`account/rateLimits/read`) — auth-proof since the codex binary owns refresh. We keep it as the v1.1 path (§2.5) because it spawns a subprocess per poll and hit a local `database is locked` error on this machine during a live codex session; wham/usage is verified working here and cheaper.

### 2.3 Grok (Grok CLI, xAI) — ◇ experimental until live-verified

- **Creds:** `~/.grok/auth.json` (respect `GROK_HOME`/`GROK_AUTH_JSON`): map of `scopeKey → {key(JWT), refresh_token, auth_mode:"oidc", oidc_issuer, oidc_client_id, email, user_id}`; filter to entries with issuer `https://auth.x.ai`. Access-token expiry from JWT `exp` claim. File absent (as on this machine) → provider state "not signed in".
- **Stream A (primary):** `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits`
  Headers: `Authorization: Bearer <key>`, `X-XAI-Token-Auth: xai-grok-cli`, `x-userid: <user_id>`, `User-Agent: GrokCLI/<version>`.
  Proto3-JSON payload: `config.creditUsagePercent` (**ring**; omitted field = 0 per proto3 defaults), `config.currentPeriod` (weekly), `config.productUsage[]`, `onDemandCap/Used`, `subscriptionTier`. Reset time from `currentPeriod` end.
- **Stream B (fallback):** tail last 8MB of `~/.grok/logs/unified.jsonl`, scan backwards for `msg=="billing: fetched credits config"`, parse same struct from `ctx.config`; fresh if ≤5min old.
- No OIDC refresh in v1 (single-use rotation risk): expired JWT → auth-error state ("Run `grok` to refresh sign-in").
- Poll: 120s (weekly window moves slowly).

### 2.4 Provider abstraction — the contributor surface

```swift
protocol UsageProvider: Sendable {
    nonisolated var id: String { get }            // "claude", "codex", "grok"
    nonisolated var displayName: String { get }
    nonisolated var glyph: ProviderGlyph { get }  // Path-drawn vector
    nonisolated var pollInterval: TimeInterval { get }
    func detect() async -> ProviderPresence       // .notInstalled / .notSignedIn / .ready
    func snapshot() async -> ProviderState        // .ok(UsageSnapshot) / .stale(UsageSnapshot, asOf) / .authError(guidance) / .unavailable
}
struct UsageSnapshot: Sendable {
    let primary: UsageWindow            // ring
    let windows: [UsageWindow]          // popover rows (primary first)
    let asOf: Date
    let detail: String?                 // "Max", "Pro plan", tier…
}
struct UsageWindow: Sendable {
    let label: String
    let percentUsed: Double             // clamped 0…100 at provider boundary
    let resetsAt: Date?
}
```
- Registry: static array of all providers; at launch each runs `detect()`; rings render only for `.ready` (menu shows detected-but-signed-out ones greyed with guidance). `.notInstalled` → invisible everywhere except an "add more" hint in the menu.
- **Contributing a provider = one new file** conforming to `UsageProvider` + one registry line + one glyph. `CONTRIBUTING.md` documents this with `GrokProvider.swift` as the worked example. Everyone is welcome; that's the product's flywheel.
- Nonisolated metadata as stored `let`s (Swift 6 strict concurrency: actors can't witness computed sync requirements).

### 2.5 Deferred (v1.1+ notes, kb-recorded so contributors can pick up)

- Claude self-refresh: `POST https://platform.claude.com/v1/oauth/token` `{grant_type: refresh_token, client_id: "9d1c250a-e61b-44d9-88ed-5944d1962f5e"}` ◇; must persist back with SHA-256 CAS + flock to avoid racing Claude Code's own rotation.
- Codex auth-proof stream via `codex app-server` JSON-RPC (`account/rateLimits/read`, refresh delegated to vendor binary) ◇; Codex token refresh: `POST https://auth.openai.com/oauth/token`, `client_id=app_EMoamEEZ73f0CkXaXp7hrann` ◇.
- Claude statusline-bridge stream (Limits' trick ◇): hook `~/.claude/settings.json` statusLine to capture live windows with zero token handling. Powerful but mutates user config — opt-in only, never default (violates "non-intrusive").
- Gemini CLI ◇: `POST https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota` (bearer from `~/.gemini/oauth_creds.json`, preceded by `:loadCodeAssist` for tier/projectId); refresh needs Google's non-public client secret — converged hack regexes `OAUTH_CLIENT_ID/SECRET` out of installed gemini-cli JS. Fragile; contributor slot.
- Copilot ◇: `GET https://api.github.com/copilot_internal/user` with GitHub OAuth token (VS Code device-flow client `Iv1.b507a08c87ecfe98`). Contributor slot.
- ~~Cursor on hold~~ **Integrated 2026-08-28** (user decision reversed same day): `CursorProvider.swift` — read-only SQLite of `state.vscdb` (`cursorAuth/accessToken`, `cachedEmail`, `stripeMembershipType`), CLI fallback `~/.cursor/auth.json`; `POST api2.cursor.sh/.../GetCurrentPeriodUsage` (Connect protocol); ring = `planUsage.totalPercentUsed`, rows for auto/API meters ≥1% + spend limit; provider id `cursor`, kept distinct from `grok` for the branding merge.

## 3. UI spec

### 3.0 Presence model (docked → shim → revealed)

Pill is **vertically centered on the right screen edge**, three states:

1. **Docked (default):** fully visible, flush to edge. Active whenever no window overlaps its frame.
2. **Shim (auto-hidden):** any normal window overlapping the pill frame → pill slides off-edge (0.25s ease-out) leaving a **5pt-wide color shim**: one vertically-stacked rounded segment per enabled provider, filled with that provider's usage color (§3.1 bands), 60% opacity, 2pt gaps, total height = pill height. Glanceable (red sliver = you're cooked), otherwise visually silent.
3. **Revealed (hover):** pointer entering a 12pt-wide hot zone along the edge spanning the shim's band (dwell 150ms, global `mouseMoved` monitor) slides the pill out **over** the overlapping window (spring, 0.3s). Stays while pointer is inside pill∪popover; collapses 500ms after exit (to Shim if overlap persists, else Docked).

- Overlap detection: `CGWindowListCopyWindowInfo(.optionOnScreenOnly)` at 1s cadence + refresh on `NSWorkspace` app-activation and space-change notifications; filter layer 0 windows on the pill's display, exclude own PID; intersect with pill frame. Frames/layer/PID need no permissions (no Screen Recording; we never read window contents/titles). Hysteresis: 300ms debounce on state transitions to avoid flapping during drags.
- All panels at `level = .statusBar` so Revealed renders above normal windows.

### 3.1 Pill

- Borderless non-activating `NSPanel`, styleMask `[.borderless, .nonactivatingPanel]`; `collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]`; transparent background; `NSApp.setActivationPolicy(.accessory)` set unconditionally in code (so `swift run` behaves like the bundle; `LSUIElement` in the plist is belt-and-braces).
- Geometry: right edge, `midY = screen.visibleFrame.midY`. Black `#000` capsule, left corner radius 24pt, right side flat to edge, top/bottom taper via 24pt-radius concave curves (per Figma). Width 64pt.
- Module (per provider): ring 36pt outer Ø, 3.5pt stroke, glyph centered (white ~16pt); percent label beneath (SF Pro 13pt semibold white, rounded to int). Module height 56pt (36 ring + 4 gap + 16 label); spacing 18pt; pill padding 16pt top/bottom. Height = 32 + N·56 + (N−1)·18 (1→88, 2→162, 3→236). Content-driven, no cap.
- Ring: track white 20%; arc from 12 o'clock clockwise = percentUsed; animate arc+color 0.4s ease-out; numbers cross-fade.
- **Usage colors (half-open bands):** `[0,50)` green #30D158 · `[50,70)` yellow #FFD60A · `[70,90)` orange #FF9F0A · `[90,100]` red #FF453A. (Mock check: 21 green, 52 yellow, 73 orange, ≥90 red.)
- **Pace escalation:** when a window with a known duration is on pace to exhaust before its reset (`percent ÷ elapsed_fraction ≥ 100`, suppressed until ≥10% of the window has elapsed), its **color** lifts one band (green→yellow→orange→red floor); displayed numbers stay raw. Applies to ring, shim, and popover bars (`UsageWindow.bandPercent`).
- **Pace pulse:** a pace-hot ring window additionally *breathes* — the pill arc and the provider's shim segment oscillate opacity (0.9s ease, autoreversing; arc 1→0.4, shim 1→0.35). Suppressed under Reduce Motion. Shim pulse is a repeating `CABasicAnimation` on a per-segment layer — render-server work, zero app CPU.
- **Home screen:** the pill lives on the Settings-picked display, else the primary display (`NSScreen.screens.first`) — never `NSScreen.main`, which follows keyboard focus and desynchronizes the presence machine from the pill's frame.
- States: before first snapshot & `.unavailable` → track-only ring, "–" label, 50% opacity. `.authError` → dimmed ring with "!" badge (auth-only state — network/decode/missing-files are all "–"). `.stale` → live colors at 70% opacity, popover shows "as of…".
- Hit-testing: pill panel accepts events in its rect (concave corner slivers are ~pt² — accepted for v1, noted). Hover/click tracking via **AppKit `NSTrackingArea` `[.activeAlways, .mouseEnteredAndExited, .mouseMoved]`** on a wrapper NSView piped into the model — SwiftUI `.onHover` does not fire in non-activating accessory panels. `acceptsFirstMouse` → true (subclass hosting view) so first click acts.

### 3.2 Popover

- Own borderless panel (not NSPopover): black HUD, corner radius 14, right-pointing tail, width 300pt, positioned left of the pill, vertically centered on the hovered ring then clamped to `screen.visibleFrame`; tail slides along the popover edge to keep pointing at the ring.
- Open: hover ring 300ms (click cancels timer, opens immediately). Exactly one popover instance; hovering another ring retargets content+tail without re-delay.
- Dismiss: hover-opened → pointer exits pill∪popover union +200ms grace. Click-opened → pinned; dismiss on click-away, Esc, or second click on same ring. Esc & click-away via local+global `NSEvent` monitors (borderless panels can't become key; responder-chain keyDown won't arrive).
- Header: glyph + "<Provider> Usage" (13pt semibold white).
- Row per `UsageWindow`: label (11pt white 90%) + right-aligned reset text (11pt white 50%); bar 4pt rounded (track white 15%, fill usage color); "73% Used" (10pt white 70%).
- Reset formatting: nil → omit; past → "resetting…" (keep last percent until next poll); `<90min` → "Resets in N min"; same-day → "Resets at h:mm a"; else "Resets Thu 12:00 AM".
- Footer (10pt white 40%): freshness ("as of 2m ago" for stale/file-based) + plan/tier.

### 3.3 Chrome & settings

- No Dock icon. Minimal status item (monochrome ring glyph): per-provider toggles, "Launch at Login", display picker, "Refresh now", greyed detected-not-signed-in providers with guidance, "Quit".
- Zero providers enabled/ready → hide pill+shim entirely; status item is the way back.
- "Refresh now" → `snapshot()` on all ready providers (incl. file re-parse) + resets backoff.
- Launch at Login: `SMAppService.mainApp`; gate the toggle on running-from-bundle; surface `.status` (e.g. `.requiresApproval`) in the menu; README documents `~/Applications` install as supported path (ad-hoc rebuilds invalidate registrations from build dirs).
- Display picker: persist display ID; on disconnect fall back to main screen; auto-return when it reappears (`didChangeScreenParametersNotification`, which also re-centers on resolution change).
- Persistence: `UserDefaults`.

## 4. Architecture & build

- Swift 6.2, macOS 15+ target (dev: macOS 26.x, Xcode 26.2). AppKit shell + SwiftUI views via `NSHostingView`. No third-party deps (URLSession, Security, CoreServices/FSEvents, ServiceManagement).
- Pure SwiftPM: executable target `Tachyon`; `build.sh` produces `Tachyon.app` (binary + generated Info.plist with `LSUIElement`, ad-hoc codesign). `swift build` must pass headlessly.
- Structure:
  ```
  Sources/Tachyon/
    App.swift                     — main, activation policy, AppDelegate, status item
    Presence/OverlapMonitor.swift — CGWindowList polling + hysteresis
    Presence/EdgeController.swift — state machine docked/shim/revealed, mouse monitors
    Panels/PillPanel.swift        — NSPanel + tracking-area wrapper view
    Panels/ShimPanel.swift
    Panels/PopoverPanel.swift
    Views/PillView.swift          — SwiftUI rings
    Views/DetailView.swift        — popover content
    Model/UsageModel.swift        — @MainActor @Observable store, scheduler, backoff
    Providers/Provider.swift      — protocol + shared types + registry
    Providers/ClaudeProvider.swift
    Providers/CodexProvider.swift
    Providers/GrokProvider.swift
    Providers/FSEventsWatcher.swift
    Glyphs.swift                  — Path-drawn provider glyphs
  build.sh
  CONTRIBUTING.md                 — "add your harness in one file" guide
  README.md
  ```
- Concurrency: providers are actors (metadata as `let`s); model `@MainActor`; FSEvents callback (C fn ptr) bridged via `Unmanaged` in the watcher class, forwarding with `Task { await … }`.
- Logging: `os.Logger` subsystem `dev.gonzih.usageo`.

## 5. Risks

| Risk | Handling |
|---|---|
| Keychain prompt on first Claude read | One-time; via `security` CLI so "Always Allow" sticks across rebuilds. README explains. |
| Endpoint/schema drift (all three are private APIs) | Optional-tolerant decode → "–" state; Codex has Stream B fallback; never crash. |
| Grok mechanics unverified on authed machine | Ships experimental-flagged; state machine handles absence gracefully; verification = first contributor task. |
| Rollout files huge | 256KB tail reads only. |
| Overlap poll cost | 1Hz CGWindowList on one display ≈ negligible; stop polling entirely while Revealed. |
| Fullscreen apps | `.fullScreenAuxiliary`; shim stays available. |
| Ad-hoc signing + SMAppService | Gated + documented (§3.3). |

## 6. Acceptance criteria (v1 done =)

1. `./build.sh` from clean checkout → `Tachyon.app`; `swift build` passes with no errors.
2. Launch on this machine → pill docked right-center; Claude ring within ±1 percentage point of `claude` `/usage` sampled the same minute; Codex ring matches `wham/usage` primary window.
3. Drag a window over the pill → collapses to color shim ≤1.5s; mouse to edge → reveals over the window; mouse away → collapses.
4. Hover ring → popover with correct rows + reset formatting; click pins; Esc dismisses.
5. Kill network → rings go "–"/stale per state rules, no crash; restore → recovery on next poll.
6. Run a Codex turn → ring updates ≤5s after rollout write (FSEvents-triggered poll).
7. Grok (unauthed here) → invisible in pill, greyed in menu with "sign in" guidance.
8. Quit via status item; launch-at-login toggle works from `~/Applications` install.
9. Idle CPU <0.5% average over 60s in Activity Monitor.

## 7. Milestones

- M1: SPM skeleton, activation policy, pill panel docked right-center, static rings.
- M2: Provider protocol + registry + Claude live end-to-end.
- M3: Codex dual-stream + Grok (experimental) + detection states.
- M4: Presence model (overlap → shim → reveal) + popover + polish.
- M5: Status item, launch-at-login, build.sh, README + CONTRIBUTING.md.

## 8. Provider settings & budgets (v1.3)

**Discipline: settings are optional refinements, never prerequisites.** Every
setting has a working default; the app is fully functional with the Settings
window never opened.

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
        case money(default: Double?)     // USD; nil = "not set"
        case toggle(default: Bool)
        case choice(options: [String], default: String)
    }
}
```

- Values persist in UserDefaults as `provider.<id>.<key>`.
- Providers read values at snapshot time via `Usage.setting(_:for:)` helpers;
  a settings change triggers an immediate re-poll of that provider.
- App renders one generic form per provider — consistent look, zero provider
  UI code.

### 8.2 Settings window

- Standard macOS settings-style window, opened from the status menu, the pill
  context menu ("Settings… ⌘,"), **and from the pill itself**: hovering the
  pill reveals a small gear affordance at its foot (fades in with the same
  ease the popovers use); clicking it opens Settings. LSUIElement app: window
  activates app temporarily.
- Left sidebar: **General** (display picker, launch at login — migrated from
  the menu; menu keeps quick toggles), then one row per *detected* provider
  (glyph + short name, matching pill visual language).
- Right pane: provider status header (presence, last poll, plan) with an
  **Enabled toggle** (same state as the menu checkmarks, `provider.enabled.*`),
  then the declared settings form. Settings-less providers show status +
  toggle — the pane doubles as a diagnostic view.

### 8.3 Budget (first declared setting)

- `OmpProvider` declares `budget.monthly` (`money`, default nil).
- Unset → current behavior: spend label ("$4.20"), neutral ring.
- Set → spend windows with a monthly period gain
  `percent = spend / budget × 100` → standard color bands, shim color, the
  whole bounded machinery. Popover caption: "$34.20 of $50".
- Bounded windows from `usage_history` still outrank budgeted spend for the
  ring (real limits beat synthetic ones).
- Future (not v1.3): auto-baseline (median of last full periods × 1.25) as
  the computed default when unset; upstream key limits (OpenRouter) as tier 2.

### 8.4 Out of scope v1.3

Per-provider notification thresholds and poll overrides (they become declared
settings later with zero protocol churn); auto-baseline; budget for
non-spend providers.
