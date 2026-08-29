# Add-your-harness prompt

Canonical source for the prompt shown in the README, on tachyon.maksim.sh, and
in the app's menu ("Add Your Harness — Copy Agent Prompt"). Change it here
first; the three embeddings mirror this text.

```text
Add support for {YOUR HARNESS} to Tachyon, the macOS usage-rings app.

1. git clone https://github.com/Gonzih/tachyon and read CONTRIBUTING.md — it defines the UsageProvider protocol and the acceptance checklist.
2. Investigate how {YOUR HARNESS} stores credentials locally and where its usage/rate-limit data lives (endpoint, log files, or CLI output).
3. Implement Sources/Tachyon/Providers/{Name}Provider.swift on the pattern of GrokProvider.swift, add one line to ProviderRegistry, add a glyph.
4. Verify with `swift run Tachyon --smoke` — your provider must show real numbers, or degrade cleanly to "not signed in".
5. Open a PR titled "provider: {name}".

NEVER LEAK CREDENTIALS. No tokens, keys, cookies, session ids, account ids, or emails — not in code, comments, test fixtures, logs, commit history, or the PR description. Credentials are read at runtime from the user's machine and go into request headers only; log lines must redact them. If smoke-test output contains identifying data, scrub it before pasting anywhere.
```
