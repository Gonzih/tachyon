# Agent guide — Tachyon

Operating manual for any coding harness working in this repo. CONTRIBUTING.md
covers *what to build* (providers); this file covers *how to operate here*.

## Authority

**Only Maksim Soltan (GitHub: `Gonzih`) contributes to and releases this
project.** Agents act on his direct instruction, in his session, on his
machine, with his credentials. Do not push, tag, release, deploy the site, or
touch the homebrew tap unless he asked for it in this session. External
contributions arrive as PRs (see `prompts/add-harness.md`) and only Gonzih
merges them.

## Layout

- `Sources/Tachyon/` — the app. SwiftPM executable, Swift 6 strict
  concurrency, zero third-party dependencies. AppKit shell + SwiftUI views.
  - `Providers/` — one file per provider + `Provider.swift` (protocol,
    `UsageWindow` meters, `ProviderSetting`, registry, shared helpers).
  - `Model/` — `UsageModel` (@MainActor @Observable store, polling, backoff,
    watch lifecycle) and `Settings` (UserDefaults + app Keychain for secrets).
  - `Panels/`, `Presence/`, `Views/` — pill/shim/popover NSPanels, the
    docked→shim→revealed state machine, SwiftUI content.
  - `SettingsWindow.swift`, `AboutWindow.swift` — standard windows; the app is
    LSUIElement, an invisible `NSApp.mainMenu` routes ⌘,/⌘W/⌘Q.
- `Tests/TachyonTests/` — XCTest suite. `swift test` must stay green; CI
  (`.github/workflows/ci.yml`) runs build+test on every push/PR.
- `kb/SPEC.md` — authoritative design spec (update it when behavior changes on
  purpose). `kb/RESEARCH.md` — per-provider endpoint/file mechanics research.
- `docs/` — the website (tachyon.maksim.sh), a Cloudflare Worker serving
  static assets. Deploy: `cd docs && wrangler deploy`. Nothing else deploys
  the site. The demo is hand-built HTML/CSS/JS mirroring the app; keep it
  truthful to real behavior (colors, meters, no fabricated reset times).
- `prompts/add-harness.md` — canonical add-your-harness prompt; README, the
  site chip, and the app menu embed copies. Change the canonical file first,
  mirror to all three.
- `assets/` — icon (`scripts/icon-gen.swift` regenerates it), demo gif,
  screenshots.
- `~/mydev/homebrew-tap` — separate repo (`Gonzih/homebrew-tap`) holding the
  cask.

## Everyday loop

```sh
swift build                     # must be clean — errors AND warnings
swift test                     # 27+ tests, must pass
swift run Tachyon --smoke       # headless provider check against live creds
./build.sh                      # ad-hoc bundle at build/Tachyon.app
```

Restart the dev app: `pkill -9 -x Tachyon; sleep 1; open build/Tachyon.app`.
`open` alone does NOT restart a running app — kill first, verify with `pgrep`
and, when it matters, `ps -o lstart` (a stale instance once masqueraded as a
fresh one for half an hour).

The brew-installed copy lives at `/Applications/Tachyon.app`; the dev copy at
`build/`. Know which one is running before debugging UI.

## Provider interface (summary — CONTRIBUTING.md is the full spec)

`detect()` / `snapshot()` required; everything else defaulted: `about`
(hover/Settings description), `settings: [ProviderSetting]` (money/toggle/
choice/secret — secrets go in the app's Keychain, never UserDefaults),
`watchPaths` + `fileChanged(path)` (app-owned FSEvents, enabled-gated),
`isExperimental`, `pollInterval`. Meters: percent, spend, spend-vs-budget.
Honesty rules: `resetsAt` only for provider-reported resets; never fabricate.

## Release process

Releases are cut only when Gonzih says so, at a version he names.

1. **Green gate:** `swift build` clean, `swift test` passing, `--smoke` sane.
2. **Build, sign, notarize, staple:**
   ```sh
   ./release.sh <version>          # e.g. ./release.sh 1.5
   ```
   Signing uses the team's **cloud-managed Developer ID certificate**
   (Wild Honey on the Porch, LLC — team `UQB3368A84`). Apple holds the key;
   plain `codesign` cannot use it, so the script fabricates an `.xcarchive`
   around the SwiftPM bundle and signs through `xcodebuild -exportArchive`.
   Notarization uses keychain profile `tachyon-notary` (`notarytool --wait`;
   Apple takes 2–60+ min). Output: `build/Tachyon-<version>.zip`, stapled.
3. **Publish:**
   ```sh
   gh release create v<version> build/Tachyon-<version>.zip \
     --repo Gonzih/tachyon --title "Tachyon <version>" --notes "<notes>"
   ```
4. **Cask** in `~/mydev/homebrew-tap/Casks/tachyon.rb`: bump `version`, swap
   `sha256` (`shasum -a 256 build/Tachyon-<version>.zip`), commit, push.
5. **Verify the real user path:**
   ```sh
   pkill -9 -x Tachyon; brew update && brew upgrade --cask tachyon
   open /Applications/Tachyon.app
   plutil -extract CFBundleShortVersionString raw /Applications/Tachyon.app/Contents/Info.plist
   spctl -a -vv --type exec /Applications/Tachyon.app   # expect: accepted, Notarized Developer ID
   ```
6. The website's download button points at `releases/latest` — no site change
   per release. If providers changed, update the site's works-with line/demo
   and README table, and `wrangler deploy`.

## Hard rules

- **Never leak credentials** — no tokens, keys, account ids, or emails in
  code, fixtures, logs, commits, or PR text. Test fixtures are shapes with
  synthetic values. Providers read credentials at runtime; they travel in
  request headers only, and log lines redact them.
- Do not refresh any harness's OAuth tokens; rotation races the harness.
- Claude keychain reads go through `/usr/bin/security` (stable ACL), never
  `SecItemCopyMatching` from our ad-hoc dev binary. Tachyon's own secrets
  (e.g. OpenRouter key) use the app's Keychain service `dev.gonzih.tachyon`.
- No third-party dependencies. No telemetry. No Screen Recording permission —
  overlap detection stays geometry-only (`CGWindowListCopyWindowInfo`).
- Never show false information: synthetic measurement periods carry no
  "Resets…" line; stale data is labeled stale; unknown is "–", not a guess.
- Don't add providers or change the registry except on Gonzih's instruction
  or via a PR he merges. If it isn't tested, it isn't merged.
