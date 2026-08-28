<p align="center"><img src="assets/icon-256.png" width="128" alt="Tachyon"></p>

# Tachyon

An edge-docked macOS utility that shows live rate-limit usage for your AI coding
harnesses. Install, launch, and a black pill appears on the right edge of your
screen with one ring per detected provider — Claude Code, Codex CLI, Grok CLI, Cursor.

No configuration. No sign-in. It reads the credentials your harnesses already
wrote and asks their own usage endpoints.


<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/screenshots/claude-dark.png">
    <img src="assets/screenshots/claude-light.png" width="420" alt="Claude usage popover next to the edge pill">
  </picture>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/screenshots/codex-dark.png">
    <img src="assets/screenshots/codex-light.png" width="420" alt="Codex usage popover next to the edge pill">
  </picture>
</p>

## Why an edge pill

`/usage` and `/status` are answers to a question you shouldn't have to ask. The
information wants to be ambient: visible at a glance, silent otherwise. So the
pill hides itself the moment a window overlaps it, leaving a 5pt color sliver at
the edge — a red sliver means you're nearly out, and that's all you need to see.
Move the pointer to the edge and the pill slides back over the window.

## Requirements

- macOS 15 or later
- Swift 6.2 toolchain (Xcode 26 or the standalone toolchain)

## Build

```sh
./build.sh
```

That produces `build/Tachyon.app` (SwiftPM release build, generated `Info.plist`,
ad-hoc code signature). To install:

```sh
cp -R build/Tachyon.app ~/Applications/
open ~/Applications/Tachyon.app
```

**Install into `~/Applications` if you want Launch at Login.** `SMAppService`
registers a bundle by path, and a registration pointing into a build directory
is invalidated by the next rebuild. The menu item is disabled when Tachyon is not
running from a bundle, and surfaces the registration status (for example
"approve in System Settings") when macOS is waiting on you.

For development, `swift run` works and behaves identically — the activation
policy is set in code, so there is never a Dock icon either way.

## Diagnostic

```sh
swift run Tachyon --smoke
```

Runs every registered provider once, headlessly, and prints what it detected:
presence, ring window, every popover row with its reset time, and the plan
string. This is the fastest way to see why a ring is blank, and the first thing
to run when contributing a provider.

## Using it

**The pill.** Right edge, vertically centered, one module per provider: ring,
glyph, percent. The ring fills clockwise from 12 o'clock and takes its color
from how much of the window you've spent — green below 50%, yellow from 50,
orange from 70, red from 90.

**States.** A `–` with a bare track means no data: no network, a schema change,
a missing file. A `!` badge means specifically an authentication problem, and the
popover tells you which command to run. Dimmed live colors mean the numbers are
real but stale, and the popover footer says how old.

**Hover a ring** for the detail popover: every window the provider reports, with
a bar and a reset time. It follows the pointer between rings without re-opening.
**Click a ring** to pin the popover; Esc, a click elsewhere, or a second click on
the same ring dismisses it.

**The status item** (a small ring in the menu bar) is the only chrome: toggle
providers on and off, pick a display, refresh immediately, quit. If every
provider is disabled or signed out, the pill and shim disappear entirely and the
status item is the way back.

## Providers

| Provider | Source | Poll |
|---|---|---|
| Claude Code | `api.anthropic.com/api/oauth/usage` | 60s |
| Codex CLI | `chatgpt.com/backend-api/wham/usage`, with rollout-log fallback | 60s + on write |
| Grok CLI | `cli-chat-proxy.grok.com/v1/billing`, with unified-log fallback | 120s |

Codex additionally watches `~/.codex/sessions` with FSEvents: when a turn
completes and writes a `token_count` event, the ring refreshes within a few
seconds instead of waiting out the poll interval.

Grok is marked **experimental**. Its mechanics come from an ecosystem
source-dive rather than a live authenticated machine, so every path degrades to
"not signed in" or "–" rather than guessing. Verifying it is a great first
contribution.

### Credentials

Tachyon never asks you for a token. It reads what your harnesses already store:

- **Claude:** `CLAUDE_CODE_OAUTH_TOKEN`, else the Keychain item
  `Claude Code-credentials`, else `~/.claude/.credentials.json`.
- **Codex:** `~/.codex/auth.json` (`$CODEX_HOME` honored).
- **Grok:** `~/.grok/auth.json` (`$GROK_HOME` / `$GROK_AUTH_JSON` honored).

**The Keychain prompt.** The first Claude read triggers one macOS Keychain
prompt. Choose **Always Allow**. Tachyon reads the item by running
`/usr/bin/security`, not by calling `SecItemCopyMatching` itself — deliberately,
because the "Always Allow" decision attaches to the binary that asked, and
Apple's `security` binary has a stable signature. Had Tachyon asked directly, its
ad-hoc signature would change on every rebuild and macOS would prompt you again
every single time. The credential is cached in memory afterwards and re-read only
when a token expires or the server returns 401.

Tachyon does not refresh anyone's OAuth tokens in v1. Refresh tokens rotate, and
racing your harness for them is a good way to break your sign-in. When a token
expires, the ring shows `!` and the popover names the command that fixes it.

## Privacy

Everything stays on your machine. Tachyon talks to the three usage endpoints
above and nowhere else — no telemetry, no analytics, no crash reporting.

The overlap detection reads window *geometry* only (frame, layer, owner PID) via
`CGWindowListCopyWindowInfo`. It never reads window contents or titles, which is
why Tachyon needs no Screen Recording permission.

## Contributing

Adding a harness is one file, one registry line, one glyph. See
[CONTRIBUTING.md](CONTRIBUTING.md) — `Sources/Tachyon/Providers/GrokProvider.swift`
is the worked example.

## License

MIT.

## Credits

Side-notch design concept by [@hivinz_](https://x.com/hivinz_/status/2092996055248126353).
Provider marks: simple-icons (CC0), Wikimedia Commons, lobehub icons (MIT).
