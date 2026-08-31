# Agent guide — Tachyon

Operating manual for any coding harness working in this repo. CONTRIBUTING.md
covers *what to build* (providers); this file covers *how to operate here*.

## Authority

**Only Maksim Soltan (GitHub: `Gonzih`) contributes to and releases this
project.** Agents act on his direct instruction, in his session, on his
machine, with his credentials. Do not push, tag, release, deploy the site, or
touch the homebrew tap unless he asked for it in this session. External
contributions arrive as PRs (see `prompts/add-provider.md`) and only Gonzih
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
- GitKB `specs/tachyon` — authoritative design spec (update it when behavior
  changes on purpose; materialized under `.kb/workspaces/<name>/`).
  `kb/RESEARCH.md` — per-provider endpoint/file mechanics research.
- `docs/` — the website (tachyon.maksim.sh), a Cloudflare Worker serving
  static assets. Deploy: `cd docs && wrangler deploy`. Nothing else deploys
  the site. The demo is hand-built HTML/CSS/JS mirroring the app; keep it
  truthful to real behavior (colors, meters, no fabricated reset times).
- `prompts/add-provider.md` — canonical add-your-provider prompt; README, the
  site chip, and the app menu embed copies. Change the canonical file first,
  mirror to all three.
- `assets/` — icon (`scripts/icon-gen.swift` regenerates it), demo gif,
  screenshots.
- `~/mydev/homebrew-tap` — separate repo (`Gonzih/homebrew-tap`) holding the
  cask.

## Everyday loop

```sh
./verify.sh                     # warning-clean build + tests + cognitive lint
./verify.sh --live              # same gate + provider check against live creds
./build.sh                      # ad-hoc bundle at build/Tachyon.app
```

`verify.sh` is the one deterministic gate used locally and in CI. Its
complexity step is intentionally exact:
`swift-complexity Sources --cognitive-only --threshold 15 --recursive`.

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
`isExperimental`, `pollInterval`. Meters: percent, spend, spend-vs-budget, count. Grouping via `category` (subscription / openHarness / infrastructure).
Honesty rules: `resetsAt` only for provider-reported resets; never fabricate.

## Release process

Releases are cut only when Gonzih says so. If he names a version, use it
exactly. If he authorizes a release without naming one, inspect the latest
stable GitHub release, Homebrew cask, and installed receipt, then increment the
final numeric component (`1.7` → `1.8`), announce it, and proceed without an
extra confirmation turn. Never infer release authorization from a build task.

1. **Version and full release scope:** confirm the version/tag does not exist,
   both repositories are clean, source `HEAD` equals `origin/main`, and CI is
   green for that SHA. Audit every unreleased commit—not only the current task:
   ```sh
   gh release list --repo Gonzih/tachyon --limit 5
   git log --reverse --oneline v<previous>..HEAD
   git diff --name-status v<previous>..HEAD
   ```
   Draft the complete user-facing changelog in the active GitKB release task
   and an ignored `build/release-notes.md`. Keep the two copies identical.
2. **Green gate:** `./verify.sh --live` (also enforced by `release.sh`) —
   warning-clean build, all tests, cognitive complexity ≤15, clean patch
   whitespace, and a sane live provider smoke run.
3. **Build, sign, notarize, staple:**
   ```sh
   ./release.sh <version>          # e.g. ./release.sh 1.5
   ```
   The version argument is mandatory; the script rejects malformed versions
   and dirty worktrees before doing expensive work.
   Signing uses the team's **cloud-managed Developer ID certificate**
   (Wild Honey on the Porch, LLC — team `UQB3368A84`). Apple holds the key;
   plain `codesign` cannot use it, so the script fabricates an `.xcarchive`
   around the SwiftPM bundle and signs through `xcodebuild -exportArchive`.
   Notarization uses keychain profile `tachyon-notary` (`notarytool --wait`;
   Apple takes 2–60+ min). Output: `build/Tachyon-<version>.zip`, stapled.
4. **Verify the exact artifact before publishing:** unpack the zip into a
   `mktemp -d` directory, then check its version, signature, Gatekeeper result,
   and staple. Record its SHA-256 and byte size in the GitKB task.
   ```sh
   shasum -a 256 build/Tachyon-<version>.zip
   plutil -extract CFBundleShortVersionString raw <unpacked>/Tachyon.app/Contents/Info.plist
   codesign --verify --deep --strict --verbose=2 <unpacked>/Tachyon.app
   spctl -a -vv --type exec <unpacked>/Tachyon.app
   xcrun stapler validate <unpacked>/Tachyon.app
   ```
5. **Publish:**
   ```sh
   gh release create v<version> build/Tachyon-<version>.zip \
     --repo Gonzih/tachyon --target <release-commit> \
     --title "Tachyon <version>" --notes-file build/release-notes.md
   ```
   Verify the published asset name, size, and server-reported digest with
   `gh release view v<version> --json assets`, and reread the published notes.
6. **Cask** in `~/mydev/homebrew-tap/Casks/tachyon.rb`: fetch first and require
   a clean, non-diverged `main`; bump `version`, swap in the artifact SHA-256,
   run `brew style Casks/tachyon.rb`, commit, and push. Then `brew update` and
   run `brew audit --cask --strict gonzih/tap/tachyon` against the published
   cask. Confirm the tap's local and remote commit hashes match.
7. **Verify the real user path:** use `brew list --cask --versions tachyon` as
   the installed-receipt check. Upgrade when installed; otherwise install the
   fully qualified cask. Kill before opening—`open` alone reuses an old process.
   ```sh
   brew list --cask --versions tachyon
   pkill -9 -x Tachyon
   brew update && brew upgrade --cask tachyon
   open /Applications/Tachyon.app
   plutil -extract CFBundleShortVersionString raw /Applications/Tachyon.app/Contents/Info.plist
   codesign --verify --deep --strict --verbose=2 /Applications/Tachyon.app
   spctl -a -vv --type exec /Applications/Tachyon.app
   xcrun stapler validate /Applications/Tachyon.app
   ps -axo pid,lstart,command | awk '/[\/]Applications\/Tachyon\.app\/Contents\/MacOS\/Tachyon$/ {print}'
   ```
   Expect the named version, a Homebrew receipt at that version, `accepted`,
   `source=Notarized Developer ID`, a valid staple, and the running executable
   under `/Applications` rather than `build/`. Record manual feedback too.
8. The website's download button points at `releases/latest` — no site change
   per release. A file under `Providers/` does not by itself require deployment:
   compare the public provider roster/demo across the full release range. When
   that public surface changes, update README/site content together and deploy
   only when Gonzih's instruction includes the site. Direct session
   instructions to skip deployment win.

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
