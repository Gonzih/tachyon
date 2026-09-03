<p align="center"><img src="assets/icon-256.png" width="128" alt="Tachyon"></p>

# Tachyon

Live rate-limit rings for Claude Code, Claude Desktop, Codex CLI, Codex Desktop,
Grok Build, Grok Bot, Cursor, Oh My Pi, OpenRouter and Ollama, docked to the
edge of your screen.
Native macOS, zero config.

<p align="center"><img src="assets/tachyon-demo.gif" width="680" alt="Tachyon: shim on the screen edge, mouse in, pill reveals, popovers per provider"></p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/screenshots/claude-dark.png">
    <img src="assets/screenshots/claude-light.png" width="410" alt="Claude popover: session and weekly bars with reset times">
  </picture>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/screenshots/codex-dark.png">
    <img src="assets/screenshots/codex-light.png" width="410" alt="Codex popover: weekly window at 100%">
  </picture>
</p>

When a window overlaps the pill it collapses to a 5pt color sliver. A warmer
sliver signals pace pressure without interrupting the work. Mouse to the edge
to bring it back. A full-screen app on Tachyon's own display hides the sliver
too; the same invisible edge hover reveals it, and other displays are ignored.

**[tachyon.maksim.sh](https://tachyon.maksim.sh)**

## Install

```sh
brew install --cask gonzih/tap/tachyon
```

or grab the notarized zip from [releases](https://github.com/Gonzih/tachyon/releases/latest).

From source:

```sh
./build.sh && cp -R build/Tachyon.app ~/Applications/
```

macOS 15+. `~/Applications` (or `/Applications`) is required for Launch at Login.

## CLI

The bundled `tachyon` command asks the running app for its already-cached
usage state. It never refreshes a provider, reads a credential, or changes
Settings.

```sh
tachyon status
tachyon status --json
```

Human output makes current, stale, unavailable, and sign-in state clear.
`--json` emits the same enabled-source snapshot with `schemaVersion: 1` and raw
usage values for harnesses. Open Tachyon first; the command does not launch it.
The signed app executable carries the CLI, and Homebrew exposes it on `PATH`
as `tachyon` with the app from the release that includes this feature.

## How it works

It discovers credentials from your existing harness sign-ins and asks their
own usage endpoints. Tachyon has no account of its own; OpenRouter is the one
source whose API key is entered explicitly in Settings.

| Provider | Source | Poll |
|---|---|---|
| Claude Code | `api.anthropic.com/api/oauth/usage` | 120s |
| Claude Desktop | read-only app cookie → `claude.ai/api/organizations/.../usage` | 120s + cookie changes |
| Codex CLI | local `$CODEX_HOME` account: direct `wham/usage`, then an isolated app-server fallback; recent CLI rollout history only while signed out | 60s + on turn completion (FSEvents) |
| Codex Desktop | recent exact-origin Desktop rollout history (read-only; current for 60s, stale until 180s) | 60s + on turn completion (FSEvents) |
| Grok Build | `cli-chat-proxy.grok.com/v1/billing`; recent unified-log history only while signed out | 120s |
| Grok Bot | read-only encrypted desktop state → `api2.cursor.sh` DashboardService | 120s |
| Cursor | `api2.cursor.sh` DashboardService, token from `state.vscdb` (read-only) | 120s |
| Oh My Pi | `~/.omp/agent/agent.db` (read-only): quota windows + `cost_usd` history | 120s |
| OpenRouter | `openrouter.ai/api/v1/auth/key` — key you add in Settings (Keychain-stored) | 120s |
| Ollama | daemon log (read-only): observed request counts — no quota API exists yet | 120s + on request |

Codex CLI and Codex Desktop are separate sources. The CLI source owns live auth
and may use a bundled app-server executable only as an isolated transport for
the selected `$CODEX_HOME` credential. The Desktop source reads only recent
rollouts explicitly marked `Codex Desktop`; it never opens managed Desktop auth
or refreshes a token. A newly written observation is current for one poll
interval, becomes stale if no later turn advances it, and expires at 180s.

Claude Code credentials are discovered from its environment, profile-specific
Keychain item, or auth file. Claude Desktop is an independent read-only source:
Tachyon decrypts a bounded applicable `claude.ai` cookie jar in memory using
Claude's Safe Storage Keychain item, requires an unambiguous session identity,
then calls Claude's own bootstrap and usage endpoints. It never writes either
app's files or credentials.

Grok Build and Grok Bot are independent products and remain independent rings.
For Grok Bot, Tachyon reads its bounded encrypted desktop state, asks the app's
own Safe Storage Keychain item to decrypt the active token in memory, then calls
the Bot usage endpoint. It never stores, logs, refreshes, or writes the token.

Every surface stays separate, even when two happen to use the same account or
quota pool. The pill keeps its scarce pixels clean—no `C`/`D` source letters;
the popover, Settings, context menu, and accessibility label name the source.

The first time Tachyon sees a provider, it performs one read-only detection
pass and enables it only when usable state already exists. Later launches keep
your choices, and disabled sources remain dormant until you enable them.

Oh My Pi needs none — its own database already carries quota windows and
per-turn cost, so the ring shows dollars when no bounded window exists.
The first read from an installed Claude or Grok Bot source may trigger its own
Keychain prompt — choose **Always Allow**. Reads go through
`/usr/bin/security`, so the approval sticks across updates. Tachyon never
refreshes anyone's tokens; an expired token shows `!` and the popover names the
command that fixes it.

Ring colors: green < 50%, yellow from 50, orange from 70, red from 90. Known
provider-enforced windows also show their projected pace; a pulse means the
current pool is on pace to hit its wall, which can mean slow down or move the
next task to another source. At 100%, the pulse stops and the ring stays red.
Personal spend budgets still
color the ring, but never pulse or claim a provider limit was reached. Hover a
ring for per-window bars and reset times; click to pin.

`swift run Tachyon --smoke` prints what every provider detects, headlessly —
first thing to run if a ring is blank.

For development, `./verify.sh` is the CI-safe green gate: warning-clean release
build, all tests, cognitive complexity ≤15, and patch whitespace. Install its
linter once with `brew install fummicc1/tap/swift-complexity`. Run
`./verify.sh --live` before a release to include the credential-backed provider
diagnostic; `release.sh` enforces that full gate automatically.

## Privacy

Talks only to the provider endpoints listed above. No telemetry. Overlap
detection reads window geometry only — no Screen Recording permission.

## Add your provider

Paste this into your coding agent — it adds itself:

```text
Add support for {YOUR PROVIDER} to Tachyon, the macOS usage-rings app.

1. git clone https://github.com/Gonzih/tachyon and read CONTRIBUTING.md — it
   defines the UsageProvider protocol and the acceptance checklist.
2. Investigate how {YOUR PROVIDER} stores credentials locally and where its
   usage/rate-limit data lives (endpoint, log files, or CLI output).
3. Implement Sources/Tachyon/Providers/{Name}Provider.swift on the pattern of
   GrokProvider.swift, add one line to ProviderRegistry, add a glyph.
4. Verify with `swift run Tachyon --smoke` — your provider must show real
   numbers, or degrade cleanly to "not signed in".
5. Open a PR titled "provider: {name}".

NEVER LEAK CREDENTIALS. No tokens, keys, cookies, session ids, account ids, or emails — not in code, comments, test fixtures, logs, commit history, or the PR description. Credentials are read at runtime from the user's machine and go into request headers only; log lines must redact them. If smoke-test output contains identifying data, scrub it before pasting anywhere.
```

Humans welcome too: [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT.

## Credits

Side-notch design concept by [@hivinz_](https://x.com/hivinz_/status/2092996055248126353).
Provider marks: simple-icons (CC0), Wikimedia Commons, lobehub icons (MIT).
