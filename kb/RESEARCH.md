# Ecosystem research — harness usage extraction mechanics

Source-dives performed through 2026-08-30, including 0xNyk/llmquota,
AmirTlinov/Limits, steipete/CodexBar, Livin21/PitStop,
eastonsuo/claude-desktop-usage, wakamex/codex-cli-usage, ryoppippi/ccusage,
Maciek-roboblog/Claude-Code-Usage-Monitor, and Dicklesworthstone/caut. ✅ =
additionally verified read-only on this machine.

## Claude (ecosystem-converged, universal)

- ✅ `GET https://api.anthropic.com/api/oauth/usage` — `Authorization: Bearer <token>`, `anthropic-beta: oauth-2025-04-20` (required), some senders spoof `User-Agent: claude-cli/<version>`. Returns `five_hour`, `seven_day`, model-scoped weeklies, generic `limits[]`, `extra_usage`, `spend`.
- Claude Code creds priority: env `CLAUDE_CODE_OAUTH_TOKEN` → active
  profile-specific Keychain service → active config `.credentials.json`.
  Custom profiles suffix `Claude Code-credentials` with the first eight
  SHA-256 hex characters of the NFC-normalized raw secure-storage/config
  override. Explicit-empty and unset semantics differ; never fall through from
  a custom service to the unsuffixed account.
- Tachyon never refreshes or writes Claude credentials. Rotation belongs to
  Claude Code; a bounded 60-second credential cache adopts changes without
  polling the Keychain twice during one snapshot cycle.
- Claude Code's endpoint limiter is shared with the harness. Tachyon therefore
  keeps a credential-scoped request deadline: 120s after every attempt and
  300s after `429`; early Refresh signals wait cancellably, while a changed
  credential bypasses the previous token's deadline. Local project JSONL can
  prove current activity but does not expose subscription-window utilization.
- Alt streams: log parsing `~/.claude/projects/**/*.jsonl` (ccusage — token accounting only, no server windows); Limits' statusline-bridge (hooks `settings.json` statusLine command, captures `rate_limits.five_hour/seven_day` piped to the statusline script; chains any pre-existing command; zero token handling but mutates user config).
- ✅ Profile endpoint `/api/oauth/profile` exposes stable account and
  organization UUID fields. HMAC both immediately to bind a Claude Code
  reading to its source-local account, and never display/persist either. Email
  is neither necessary nor safe for usage attribution. Tachyon deliberately
  does not merge Code and Desktop even when these values match.
- ✅ Claude Desktop stores Chromium cookies at
  `~/Library/Application Support/Claude/{Cookies,Network/Cookies}` and its
  encryption password in Keychain service `Claude Safe Storage`. Local schema
  24 uses `v10`/`v11` AES-128-CBC values with PBKDF2-HMAC-SHA1 (`saltysalt`,
  1003 rounds, 16-byte key, space IV) plus a 32-byte SHA-256 host binding that
  must be verified before stripping.
- Desktop discovery is a matrix, not one hard-coded path: resolve bundle ID
  `com.anthropic.claudefordesktop`, then `/Applications/Claude.app` and
  `~/Applications/Claude.app`; search an absolute non-empty inherited
  `CLAUDE_USER_DATA_DIR` before the standard support root; try
  `Network/Cookies` and then legacy `Cookies` for every root. A readable empty
  database cannot mask a later authenticated candidate.
- Desktop route, corroborated by
  [PitStop](https://github.com/Livin21/pitstop/blob/master/Sources/PitStop/ClaudeDesktop.swift)
  and
  [claude-desktop-usage](https://github.com/eastonsuo/claude-desktop-usage):
  replay only the bounded applicable `claude.ai` cookie jar with the installed
  app's current Chromium UA, call `/api/bootstrap`, select the active
  chat-capable organization, then `/api/organizations/{org}/usage`. Cookies
  and raw IDs stay in memory; do not use curl/Python, persist cookies, or log
  inventories/bodies.
- Cookie replay is not equivalent to choosing one row: Chromium can retain
  duplicate host-only/domain/path variants. Tachyon loads identity cookies in a
  dedicated set capped at 64 rows and general cookies separately (512 rows
  total); the load fails closed above 64 identity rows. Each request accepts at
  most 128 safe cookies/32KiB and prioritizes identity cookies. It requires one
  identical unambiguous `sessionKey` across bootstrap/API/usage scopes and
  rejects conflicting `lastActiveOrg` values. This prevents a stale duplicate
  or junk-row flood from silently selecting the wrong Desktop session.
- Desktop state and its verified account+organization HMAC are produced by one
  poll. Canceled session loads do not update session/context or last-good
  caches, so canceled work from a prior account cannot overwrite a newer choice.

## Codex CLI + Desktop (independent sources)

Re-verified 2026-08-30 against OpenAI's current [app-server manual](https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md), [account protocol](https://github.com/openai/codex/blob/main/codex-rs/app-server-protocol/src/protocol/v2/account.rs), [backend route selection](https://github.com/openai/codex/blob/main/codex-rs/backend-client/src/client/rate_limit_resets.rs), and [auth manager](https://github.com/openai/codex/blob/main/codex-rs/login/src/auth/manager.rs).

1. ✅ **Direct bearer usage (Tachyon primary):** `GET https://chatgpt.com/backend-api/wham/usage` — `Authorization: Bearer <tokens.access_token>` plus `ChatGPT-Account-Id` only when non-empty (from `$CODEX_HOME/auth.json`; account-id fallback = id-token JWT claim). No `Content-Type` on the GET. Returns `plan_type`, independently optional `rate_limit.primary_window/secondary_window {used_percent, limit_window_seconds, reset_at}`, `additional_rate_limits[]` (per-model), `credits`. Codex's current backend client normalizes ChatGPT hosts to `/backend-api` and selects `/wham/usage`; non-`backend-api` bases select `/api/codex/usage`. Tachyon accepts only HTTPS custom bases, except explicit loopback HTTP (`localhost`, IPv4 `127/8`, `[::1]`), and rejects userinfo/query/fragment before either direct use or app-server forwarding. This is cheaper than a subprocess and does not invoke Codex's auth manager.
2. **`codex app-server` JSON-RPC (Tachyon best-effort fallback):** bundled ChatGPT executable first, then resolved CLI; stdio lifecycle `initialize` (experimental API) → `initialized` → experimental `account/login/start {type:"chatgptAuthTokens", accessToken, chatgptAccountId, chatgptPlanType?}` → `account/rateLimits/read` and optional `account/usage/read`. The external token lives in memory and carries no refresh token. Run only with a new empty `0700` `CODEX_HOME`, strip inherited token env vars, disable analytics, cap line/total output and wall time, reject `account/chatgptAuthTokens/refresh`, then kill and remove the home. `rateLimitsByLimitId` may contain side pools; prefer `"codex"`, hide untouched pools, and apply the worst-window rule. `account/usage/read` supplies optional daily token-activity buckets; `rateLimitResetCredits.availableCount` is authoritative when present.
3. ✅ **Session logs:** `$CODEX_HOME/sessions/YYYY/MM/DD/rollout-*.jsonl`, `event_msg`/`token_count` events → `rate_limits.primary/secondary {used_percent, window_minutes, resets_at}`, `total_token_usage` (cumulative counters → delta with reset-epoch handling, per Limits). The records carry no account identity: Tachyon never attaches them to an authenticated credential. `session_meta.payload.originator == "Codex Desktop"` is a reliable exact surface marker in current local Desktop rollouts; CLI accepts every other/legacy originator and Desktop accepts only that exact marker. Signed-out CLI history remains stale-only. An exact-origin Desktop observation is current for 60s, stale until 180s total age, then unavailable; timestamps up to 60s in the future tolerate clock skew. Tail bytes are fixed; traversal scans at least five newest day directories, continues until it finds five surface-matching candidates, and retains an independent 2,048-directory safety ceiling. Reject ineligible timestamps before selecting the newest eligible event, so one corrupt future record cannot hide a valid candidate; never trust file mtime as event freshness. (`archived_sessions` exists upstream but is not part of Tachyon's current bounded fallback.)

- **Important correction to the earlier audit:** managed app-server is not “auth-proof.” Current official Codex `account/rateLimits/read` and `account/usage/read` obtain auth through `AuthManager.auth()`, which may proactively refresh managed ChatGPT OAuth near expiry. `account/read {refreshToken:false}` only suppresses that method's requested refresh; it does not make the other reads non-refreshing. Tachyon must never point the probe at the user's real `CODEX_HOME`, copy/symlink `auth.json`, supply a refresh token, or write rotated credentials back.
- The external `chatgptAuthTokens` login/refresh bridge is explicitly marked unstable and for internal use in the upstream schema. Treat absence, rejection, timeout, output drift, or an unauthorized refresh callback as an ordinary fallback miss—not permission to switch to managed auth.
- The ChatGPT/Codex-bundled executable is only a process host for the CLI
  fallback. External auth still uses the token/account id already read from
  `$CODEX_HOME`; it does not export a different Desktop login. The separate
  Desktop source therefore reads exact-originator rollout history only. The
  running Desktop child exposes no attachable control socket found in local
  inspection, and no safe documented non-refreshing Desktop credential/usage
  export is currently verified.
- Plan without any call: decode `auth.json` `tokens.id_token` JWT claim `https://api.openai.com/auth`.`chatgpt_plan_type`.
- The scheduler reading is fingerprinted from the exact access token/account id
  used by the direct/probe attempt. This fingerprint is per-launch HMAC data,
  never a persisted credential or account identifier; if the required account
  context is unavailable, identity remains nil.

## Grok Build (from llmquota source; unverified live — no auth.json on this machine)

- Creds: `~/.grok/auth.json` (`GROK_HOME`/`GROK_AUTH_JSON` overrides): map `scopeKey → {key(JWT), refresh_token, auth_mode:"oidc", oidc_issuer, oidc_client_id, email, user_id}`; filter issuer `https://auth.x.ai`; expiry = JWT `exp`.
- Primary: `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits` — `Authorization: Bearer <key>`, `X-XAI-Token-Auth: xai-grok-cli`, `x-userid: <user_id>`, `User-Agent: GrokCLI/<version>`. Proto3-JSON: `config.creditUsagePercent` (omitted = 0), `config.currentPeriod`, `productUsage[]`, `onDemandCap/Used`, `subscriptionTier`. Periods can be weekly or monthly; use an authoritative positive `currentPeriod.end − start` as the pace duration rather than fabricating seven days. (Installed `@xai-official/grok` binary contains `auth.json` string — consistent.)
- Signed-out history: tail 8MB of `~/.grok/logs/unified.jsonl`, backwards-scan
  `msg=="billing: fetched credits config"` → same struct in `ctx.config`; accept
  only records ≤5min old and no more than 60s in the future. Unified logs have
  no account identifier, so authenticated request/auth failures fail closed
  instead of presenting them as the current account.
- Auth probe only: `GET https://api.x.ai/v1/models` (403 message regex).
- OIDC refresh mechanics exist (`<issuer>/.well-known/openid-configuration` →
  token endpoint, `grant_type=refresh_token`) but rotation is single-use;
  Tachyon does not call them and only adopts credentials written by the CLI.
- Live readings bind state to a per-launch HMAC of the exact key and available
  user context. Missing context yields nil identity rather than a guessed match.

## Grok Bot — integrated and verified live 2026-09-01

- This is a separate product from Grok Build. SpaceXAI's product page says the
  beta has its own usage, separate from Grok and Cursor plans. The installed
  signed app is Anysphere's `com.anysphere.sand` Electron bundle.
- The active account token is inside the bounded
  `~/Library/Application Support/Grok Bot/sand-secrets.json` account store,
  encrypted with Electron Safe Storage. Tachyon reads the app-owned
  `Grok Bot Safe Storage` Keychain item through `/usr/bin/security`, derives the
  Chromium `v10` AES key, and decrypts only in memory. It never writes the file,
  persists the token, or invokes any refresh path.
- `POST https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus`
  uses Connect JSON and returns the Bot pool's `usagePercent`, period start,
  next reset, trial expiry, availability, and plan label. A live read on this
  machine returned a usable Bot snapshot without printing credentials or
  identifiers.
- A live trial is labeled `Trial`; its expiry is shown as an explicit
  `Trial ends …` footer, not presented as a recurring reset or used for pace
  projection. If the provider retains an elapsed timestamp, the footer changes
  to `Trial ended …`. Outside a trial, authoritative positive period start/end
  values supply the weekly reset and duration.
- Missing Keychain access, an invalid envelope/account scope, expired or 401
  credentials, malformed usage, cancellation, and network failures fail closed.

## Google Antigravity / AGY — integrated and verified live 2026-09-04

- Official AGY exposes quota data through its documented non-interactive
  command: `agy --print /usage --output-format json --print-timeout 20s`.
  The JSON envelope is `command.data.groups[].buckets[]`; each usable bucket
  carries `remaining_fraction` (0...1), optional `reset_time`, and optional
  `window`. Tachyon renders `used = (1 - remaining_fraction) * 100`, keeps only
  provider-reported resets, and uses compact numeric durations only when AGY
  supplies them.
- Google's [model documentation](https://antigravity.google/docs/models/)
  shows separate Gemini and Claude/GPT quota groups with repeated weekly and
  five-hour bucket titles. Preserve the parent group in each row label and
  remove “Limit Remaining” from the period title to match the percent-used
  meter. Do not infer a measurement duration from the display title.
- The provider resolves the installed executable (`~/.local/bin/agy`, standard
  Homebrew paths, then `PATH`) and runs only that documented command with a
  25-second wall-clock and 512KiB output bound. It does not read AGY config,
  credentials, tokens, account identity, or Keychain, and implements no OAuth
  refresh. AGY manages its own sign-in and any internal auth or session writes.
- AGY's official output is account-level and does not distinguish Desktop from
  CLI activity. Tachyon intentionally displays one `antigravity` ring rather
  than fabricate two source-specific allowances. A desktop-only install is
  detected but needs AGY CLI installed for the readout.
- The in-app mark is Google's official Antigravity product SVG arch, rendered
  monochrome like the rest of Tachyon's glyphs; no third-party artwork ships.

## Cursor — integrated 2026-08-28

- Token from read-only `state.vscdb` SQLite `ItemTable` key
  `cursorAuth/accessToken` (or `~/.cursor/auth.json`); `POST
  https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage`
  uses the Connect protocol. Tachyon deliberately does not read cached email.
- State and its per-launch credential fingerprint come from the same token and
  available membership context. A 401 clears only the matching cached token;
  cancellation or a newer token cannot be overwritten by the old request.
- `billingCycleStart/End` have appeared as ISO strings, epoch seconds, and
  epoch-millisecond numbers/strings. Parse those locally and propagate a
  positive `end − start` duration to Billing cycle, Auto, API, and Spend limit;
  malformed/reversed periods keep the reset when valid but disable projection.

## Future provider slots (documented paths)

- **Gemini CLI**: `POST https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota` `{project}` after `:loadCodeAssist` (tier+projectId; project discovery via `cloudresourcemanager.googleapis.com/v1/projects`, `gen-lang-client*`). Creds `~/.gemini/oauth_creds.json`; refresh `oauth2.googleapis.com/token` needs non-public client secret → CodexBar regexes `OAUTH_CLIENT_ID/SECRET` from installed `@google/gemini-cli-core/dist/src/code_assist/oauth2.js`. Fragile.
- **Copilot**: `GET https://api.github.com/copilot_internal/user`, `Authorization: token <gh_oauth>`; device flow client `Iv1.b507a08c87ecfe98`.
- **Hermes/Nous**: `GET {portal}/api/oauth/account`, portal default `https://portal.nousresearch.com`; creds `~/.hermes/auth.json`; refresh rotates single-use tokens (adopt-don't-refresh pattern).

## Design patterns worth stealing

- Layered per-provider source strategy: `auto | oauth | cli | logs` with graceful fallback (CodexBar).
- Zero-config detection: probe env → keychain → dotfiles; decode JWT claims for plan/account; fingerprint installed CLIs by path candidates + markers (llmquota's 17-CLI catalog, 2.5s memo).
- Prefer a harness's own IPC only when its credential lifecycle is compatible with Tachyon's no-refresh rule; Codex managed app-server is not, while its isolated external-token bridge is a guarded best-effort exception.
- Incremental log import: per-file `{inode, byteOffset, parserState}` cursors; inode change → rescan; only consume complete lines (Limits).
- Schema-drift guard: `hasAnyOwn(value, KNOWN_FIELDS)` before trusting a payload (llmquota).
- Freshness as first-class UI state (`freshUntil = generatedAt + TTL`), never silently stale (Limits).
- Account identity must be atomic with the reading. Provider-scoped credential
  fingerprints prevent source-local cross-account stale inheritance; they do
  not merge product surfaces. Never fingerprint a newly reloaded credential
  after awaiting a request made with an older one.
- Unbound logs/rollouts are signed-out history only, with explicit past/future
  bounds. The model separately expires every unchanged stale timestamp after
  three poll intervals and remembers expired watermarks, so repeated parsing
  cannot make one old record immortal.
- Shared ingestion bounds: small files use explicit per-provider ceilings;
  `tailLines` reads only the requested tail and rejects byte counts above 16MiB;
  request headers reject non-ASCII/control data and cap size; HTTP bodies stream
  into a 4MiB hard cap and cancel immediately on overflow.

## OpenRouter — verified live 2026-08-28

Both endpoints take `Authorization: Bearer <key>`; scopes differ:

- `GET /api/v1/credits` — **account-wide**: `total_credits` (prepaid),
  `total_usage` (all keys, lifetime). The main metric → ring. Prepaid, never
  refreshes → no reset time.
- `GET /api/v1/auth/key` — **this key only**: cumulative `usage`, optional
  `limit`/`limit_remaining`, `is_free_tier`, plus native `usage_daily`/
  `usage_weekly`/`usage_monthly` (added upstream sometime post-launch — could
  replace Tachyon's month-baseline hack) and `byok_usage*` variants. Spend
  through other keys (e.g. omp's own credential store) is invisible here.
- The exact key plus its non-secret revision fingerprints each reading and
  scopes the month-start baseline. Updating the Keychain item to the same
  non-empty value is a no-op: no revision bump and no accidental baseline reset.
  A key change during an in-flight read discards that result.

## Competitive field (for positioning)

CodexBar (Swift menu bar, ~90 providers), Limits (Swift menu bar,
Codex+Claude), PitStop (native Swift menu bar with Claude Desktop cookie
support), ccseva, llmquota, ccusage, caut, and assorted tray/TUI tools. Nobody
does an edge-docked ambient pill with an overlap-aware shim and four explicitly
separate Claude/Codex app and CLI sources. That's our lane.


## Oh My Pi (omp) — verified live 2026-08-28

npm `@oh-my-pi/pi-coding-agent` (bun runtime), config root `~/.omp`
(`PI_CONFIG_DIR` override). Everything Tachyon needs is in SQLite
`~/.omp/agent/agent.db` (read-only):

- `usage_history(recorded_at, provider, account_key, email, account_id,
  limit_id, label, window_label, used_fraction, status, resets_at)` — hourly
  bounded-window snapshots for subscription/OAuth accounts → percent ring.
  Never read email/account_id.
- `usage_cost_history(recorded_at, provider, account_key, cost_usd)` — omp
  computes per-turn cost itself (client-side, model catalog in models.db) →
  spend meter, no pricing tables on our side.
- `auth_credentials` — multi-account store; 73 provider registry incl.
  OpenRouter (validated via openrouter.ai/api/v1/auth/key), locals
  (ollama/lm-studio/llama.cpp/vllm).
- `model_usage(model_key, last_used_at)` — one row per model ever run;
  newest row = footer (the model actually in use). `config.yml`
  `modelRoles.default` is only a fallback — per-session model switches
  never rewrite it, so it goes stale.
- No monetary budget setting exists in omp's settings schema.
- Session JSONLs: `~/.omp/agent/sessions/<encoded-cwd>/<ts>_<uuid>.jsonl`,
  assistant messages carry `usage.cost.total`; `omp usage --json` and
  `omp stats --json` exist but spawn bun — SQLite is the cheap path.
- Spend design shipped: ring = worst bounded window when any exists, else
  "$X today" spend label (UsageWindow.spendUSD, additive to the protocol).


## Ollama — observed-activity provider (no quota API)

No usage/quota API exists, local or cloud. Confirmed via omp'''s own fetcher
(pi-ai/src/usage/ollama.ts): an empty stub noting "Ollama does not expose a
standalone quota usage API; per-response token usage is reported during
requests" — registered "until a quota endpoint is available." Local ollama
additionally has nothing to meter (no limits, no cost).

Decision (superseded same day by Gonzih): ship an *observed activity* provider
instead — request counts parsed from the daemon's GIN log (2xx POSTs to
inference endpoints; log carries no model names, so no cloud/local split, and
windows are labeled plainly as requests). New `count` meter added to
UsageWindow for it. Experimental until verified against a signed-in cloud
account. Original finding stands:
Ollama Cloud used through omp is already metered transitively (omp records
per-response cost in agent.db, which OmpProvider reads). Revisit when Ollama
ships a quota endpoint; keys/identity likely under ~/.ollama.
