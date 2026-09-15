---
name: release
description: Publish a Tachyon macOS release when Gonzih explicitly authorizes it. Use only in this repository; covers the signed app, GitHub release, Homebrew cask, and updater-test path.
---

# Tachyon release

Use this only from the Tachyon repository and only after Gonzih explicitly
authorizes a release in the current session. This is a public repository:
never put credentials, tokens, account data, private keychain names, or signing
identifiers in git, notes, logs, or release copy.

## Preflight

If no version is named, inspect the latest stable GitHub release, the cask, and
the installed receipt; increment the final numeric component. Confirm the tag
does not exist, source `HEAD` equals `origin/main`, both repositories are
clean, CI is green for that exact SHA, and audit the full range since the prior
tag—not just the current feature.

```sh
git fetch --prune origin
gh release list --repo Gonzih/tachyon --limit 5
git log --reverse --oneline v<previous>..HEAD
git diff --name-status v<previous>..HEAD
gh run list --repo Gonzih/tachyon --branch main --limit 8
brew list --cask --versions tachyon
plutil -extract CFBundleShortVersionString raw /Applications/Tachyon.app/Contents/Info.plist
```

Create or update `tasks/release-<version>` in GitKB. It must contain the
complete user-facing changelog, release decisions, and later artifact evidence.
Write the same changelog to ignored `build/release-notes.md`; the GitHub
release body must use that exact file.

## Source release

Commit and push all approved release work first. Recheck that `HEAD` equals
`origin/main`, source CI is green, and the worktree is clean. Do not deploy the
website merely because a release exists; deploy it only when Gonzih explicitly
includes the site in scope.

Run the release script once:

```sh
./release.sh <version>
```

It owns the live gate, cloud signing, notarization, stapling, and output zip.
Do not run a separate `./verify.sh --live` beforehand: that duplicates private
credential access and can create unnecessary prompts. Do not refresh OAuth or
retry credential access in an effort to make the gate pass.

Verify the exact emitted artifact before publishing. Unpack into a `mktemp -d`
directory and record its SHA-256, byte size, version, strict signature,
Gatekeeper result, and staple in the release task. Verify the bundled CLI by
invoking the app executable through a temporary lowercase `tachyon` symlink;
do not add or ship another helper executable.

## Publish and cask

Create the GitHub release for the verified source SHA using
`build/Tachyon-<version>.zip` and `build/release-notes.md`. Reread published
notes and verify GitHub's asset name, size, and digest.

Then update `~/mydev/homebrew-tap/Casks/tachyon.rb`: fetch first, require a
clean non-diverged `main`, replace only the version and verified SHA-256, retain
the app-backed lowercase `tachyon` binary stanza, run `brew style`, commit, and
push. Confirm local and remote tap commits match.

For a normal release, run `brew update` and
`brew audit --cask --strict gonzih/tap/tachyon`, then upgrade the installed
app and verify its version, receipt, signature, Gatekeeper result, staple, and
running path under `/Applications`.

For an explicitly requested in-app updater test, do not run Homebrew metadata
refresh, upgrade, or named audit after publishing the cask. Leave the old
installed receipt and tap checkout intact; the app's update action performs
the real test. Run the deferred audit and installed-artifact checks after
Gonzih reports that result.

## Finish

Record commands, SHA-256, byte size, publication URLs, cask commit, and any
deferred manual check in the GitKB release task. Mark it complete only after
the requested release path is verified. Never release, push, tag, deploy, or
touch the tap without current-session authorization.
