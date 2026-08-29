# Agent guide — Tachyon

Operating notes for any coding harness working in this repo.

## Authority

**Only Maksim Soltan (GitHub: `Gonzih`) contributes to and releases this
project.** Agents act on his direct instruction in his session, on his machine,
with his credentials. Do not push, tag, release, deploy the site, or touch the
homebrew tap unless he asked for it in this session. External contributions
arrive as PRs (see `prompts/add-harness.md`) and only Gonzih merges them.

## Layout

- `Sources/Tachyon/` — the app. SwiftPM, Swift 6 strict concurrency, zero
  dependencies. `swift build` must stay clean (no errors, no warnings).
- `kb/SPEC.md`, `kb/RESEARCH.md` — design spec and provider-endpoint research.
  The spec is authoritative; update it when behavior changes on purpose.
- `docs/` — the website (tachyon.maksim.sh), a Cloudflare Worker serving static
  assets. Deploy: `cd docs && wrangler deploy`. Nothing else deploys the site.
- `prompts/add-harness.md` — canonical add-your-harness prompt. The README,
  the website chip, and the app menu embed copies; change the canonical file
  first, then mirror to all three.
- `~/mydev/homebrew-tap` — separate repo (`Gonzih/homebrew-tap`) holding the
  cask.

## Everyday verification

```sh
swift build                     # must be clean
swift run Tachyon --smoke       # headless provider check against live creds
./build.sh                      # ad-hoc bundle at build/Tachyon.app
```

Restart the dev app: `pkill -9 -x Tachyon; open build/Tachyon.app`. Note that
`open` alone does NOT restart a running app — kill first, verify with `pgrep`.

## Release process

Releases are cut only when Gonzih says so, at a version he names.

1. **Build, sign, notarize, staple:**
   ```sh
   ./release.sh <version>          # e.g. ./release.sh 1.2
   ```
   Signing uses the team's **cloud-managed Developer ID certificate**
   (Wild Honey on the Porch, LLC — team `UQB3368A84`). Apple holds the key;
   plain `codesign` cannot use it, so the script fabricates an `.xcarchive`
   around the SwiftPM bundle and signs through `xcodebuild -exportArchive`.
   Notarization uses the keychain profile `tachyon-notary` (`notarytool`).
   Apple's queue takes anywhere from 2 to 60+ minutes; the script waits.
   Output: `build/Tachyon-<version>.zip`, stapled and Gatekeeper-clean.

2. **Publish the GitHub release:**
   ```sh
   gh release create v<version> build/Tachyon-<version>.zip \
     --repo Gonzih/tachyon --title "Tachyon <version>" --notes "<notes>"
   ```

3. **Update the cask** in `~/mydev/homebrew-tap/Casks/tachyon.rb`:
   `version` and `sha256` (`shasum -a 256 build/Tachyon-<version>.zip`),
   commit, push.

4. **Verify the real user path:**
   ```sh
   pkill -9 -x Tachyon
   brew update && brew upgrade --cask tachyon
   open /Applications/Tachyon.app
   plutil -extract CFBundleShortVersionString raw /Applications/Tachyon.app/Contents/Info.plist
   ```

5. The website's download button points at `releases/latest` — no site change
   needed per release.

## Hard rules

- **Never leak credentials** — no tokens, account ids, or emails in code,
  fixtures, logs, commits, or PR text. Providers read credentials at runtime
  and send them in request headers only.
- Do not refresh any harness's OAuth tokens; rotation races the harness.
- Keychain reads go through `/usr/bin/security` (stable ACL), never
  `SecItemCopyMatching` from our ad-hoc dev binary.
- No third-party dependencies. No telemetry. No Screen Recording permission —
  overlap detection stays geometry-only.
- Don't add providers behind Gonzih's back; the registry changes only via his
  instruction or a PR he merges.
