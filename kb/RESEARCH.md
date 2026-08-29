# Ecosystem research — harness usage extraction mechanics

Source-dives performed 2026-08-28 (repos: 0xNyk/llmquota, AmirTlinov/Limits, steipete/CodexBar, wakamex/codex-cli-usage, ryoppippi/ccusage, Maciek-roboblog/Claude-Code-Usage-Monitor, Dicklesworthstone/caut, + web-verified others). ✅ = additionally verified live on this machine.

## Claude (ecosystem-converged, universal)

- ✅ `GET https://api.anthropic.com/api/oauth/usage` — `Authorization: Bearer <token>`, `anthropic-beta: oauth-2025-04-20` (required), some senders spoof `User-Agent: claude-cli/<version>`. Returns `five_hour`, `seven_day`, model-scoped weeklies, generic `limits[]`, `extra_usage`, `spend`.
- Creds priority: env `CLAUDE_CODE_OAUTH_TOKEN` → Keychain service `"Claude Code-credentials"` (JSON blob `claudeAiOauth{accessToken, refreshToken, expiresAt, subscriptionType, rateLimitTier}`) → `$CLAUDE_CONFIG_DIR|~/.claude/.credentials.json`.
- Refresh (we defer to v1.1): `POST https://platform.claude.com/v1/oauth/token` `{grant_type: refresh_token, client_id: "9d1c250a-e61b-44d9-88ed-5944d1962f5e"}`; persist back with CAS + flock (llmquota does keychain via `security add-generic-password -U`).
- Alt streams: log parsing `~/.claude/projects/**/*.jsonl` (ccusage — token accounting only, no server windows); Limits' statusline-bridge (hooks `settings.json` statusLine command, captures `rate_limits.five_hour/seven_day` piped to the statusline script; chains any pre-existing command; zero token handling but mutates user config).
- Profile endpoint: `/api/oauth/profile`.

## Codex (three mechanisms, ranked)

1. **`codex app-server` JSON-RPC** (CodexBar + wakamex primary): spawn `codex -s read-only -a never app-server` (stdio), `initialize` → `initialized` → `account/read` → `account/rateLimits/read` → `rate_limits_by_limit_id` (prefer key `"codex"`). Auth-proof: codex binary owns token refresh. Caveat found here: `database is locked` error while a live codex session runs. Limits runs it with sandboxed `CODEX_HOME` tempdir for multi-account probing, CAS-writeback of rotated tokens.
2. ✅ **`GET https://chatgpt.com/backend-api/wham/usage`** — `Authorization: Bearer <tokens.access_token>`, `ChatGPT-Account-Id: <tokens.account_id>` (from `~/.codex/auth.json`, `$CODEX_HOME` honored; account_id fallback = id_token JWT). Returns `plan_type`, `rate_limit.primary_window/secondary_window {used_percent, limit_window_seconds, reset_at}`, `additional_rate_limits[]` (per-model), `credits`. Companion: `GET .../wham/rate-limit-reset-credits` (add `OpenAI-Beta: codex-1`, `originator: Codex Desktop`). Variant seen elsewhere: `GET .../backend-api/codex/usage` (wakamex; 403 for us, wham 200 ✅).
3. ✅ **Session logs**: `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` (+`archived_sessions`), `event_msg`/`token_count` events → `rate_limits.primary/secondary {used_percent, window_minutes, resets_at}`, `total_token_usage` (cumulative counters → delta with reset-epoch handling, per Limits). Stale between runs.

- Token refresh: `POST https://auth.openai.com/oauth/token`, `grant_type=refresh_token`, `client_id=app_EMoamEEZ73f0CkXaXp7hrann`.
- Plan without any call: decode `auth.json` `tokens.id_token` JWT claim `https://api.openai.com/auth`.`chatgpt_plan_type`.

## Grok (from llmquota source; unverified live — no auth.json on this machine)

- Creds: `~/.grok/auth.json` (`GROK_HOME`/`GROK_AUTH_JSON` overrides): map `scopeKey → {key(JWT), refresh_token, auth_mode:"oidc", oidc_issuer, oidc_client_id, email, user_id}`; filter issuer `https://auth.x.ai`; expiry = JWT `exp`.
- Primary: `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits` — `Authorization: Bearer <key>`, `X-XAI-Token-Auth: xai-grok-cli`, `x-userid: <user_id>`, `User-Agent: GrokCLI/<version>`. Proto3-JSON: `config.creditUsagePercent` (omitted = 0), `config.currentPeriod` (weekly), `productUsage[]`, `onDemandCap/Used`, `subscriptionTier`. (Installed `@xai-official/grok` binary contains `auth.json` string — consistent.)
- Fallback: tail 8MB of `~/.grok/logs/unified.jsonl`, backwards-scan `msg=="billing: fetched credits config"` → same struct in `ctx.config`; fresh ≤5min.
- Auth probe only: `GET https://api.x.ai/v1/models` (403 message regex).
- OIDC refresh: `<issuer>/.well-known/openid-configuration` → token endpoint, `grant_type=refresh_token`; single-use rotation — persist immediately, prefer adopting fresher tokens written by the CLI.

## Future provider slots (documented paths)

- **Gemini CLI**: `POST https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota` `{project}` after `:loadCodeAssist` (tier+projectId; project discovery via `cloudresourcemanager.googleapis.com/v1/projects`, `gen-lang-client*`). Creds `~/.gemini/oauth_creds.json`; refresh `oauth2.googleapis.com/token` needs non-public client secret → CodexBar regexes `OAUTH_CLIENT_ID/SECRET` from installed `@google/gemini-cli-core/dist/src/code_assist/oauth2.js`. Fragile.
- **Copilot**: `GET https://api.github.com/copilot_internal/user`, `Authorization: token <gh_oauth>`; device flow client `Iv1.b507a08c87ecfe98`.
- **Cursor**: token from `state.vscdb` SQLite `ItemTable` key `cursorAuth/accessToken` (or `~/.cursor/auth.json`); `POST https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage` (Connect protocol) or cursor.com dashboard APIs with `WorkosCursorSessionToken` cookie.
- **Hermes/Nous**: `GET {portal}/api/oauth/account`, portal default `https://portal.nousresearch.com`; creds `~/.hermes/auth.json`; refresh rotates single-use tokens (adopt-don't-refresh pattern).

## Design patterns worth stealing

- Layered per-provider source strategy: `auto | oauth | cli | logs` with graceful fallback (CodexBar).
- Zero-config detection: probe env → keychain → dotfiles; decode JWT claims for plan/account; fingerprint installed CLIs by path candidates + markers (llmquota's 17-CLI catalog, 2.5s memo).
- Prefer the harness's own IPC over re-implementing auth (app-server RPC).
- Incremental log import: per-file `{inode, byteOffset, parserState}` cursors; inode change → rescan; only consume complete lines (Limits).
- Schema-drift guard: `hasAnyOwn(value, KNOWN_FIELDS)` before trusting a payload (llmquota).
- Freshness as first-class UI state (`freshUntil = generatedAt + TTL`), never silently stale (Limits).

## Competitive field (for positioning)

CodexBar (Swift menu bar, ~90 providers), Limits (Swift menu bar, Codex+Claude), ccseva (Swift menu bar, Claude), llmquota (TUI), ccusage (CLI statusline), caut (Rust CLI), assorted Python tray/TUI tools. Nobody does an edge-docked ambient pill with overlap-aware shim. That's our lane.


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
- No monetary budget setting exists in omp's settings schema.
- Session JSONLs: `~/.omp/agent/sessions/<encoded-cwd>/<ts>_<uuid>.jsonl`,
  assistant messages carry `usage.cost.total`; `omp usage --json` and
  `omp stats --json` exist but spawn bun — SQLite is the cheap path.
- Spend design shipped: ring = worst bounded window when any exists, else
  "$X today" spend label (UsageWindow.spendUSD, additive to the protocol).
