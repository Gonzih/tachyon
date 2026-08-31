#!/bin/bash
# One reproducible green gate for local work, CI, and release preparation.
#
#   ./verify.sh          deterministic checks safe for CI
#   ./verify.sh --live   same checks plus live provider diagnostics
set -euo pipefail
cd "$(dirname "$0")"

LIVE=0
case "${1:-}" in
    "") ;;
    --live) LIVE=1 ;;
    -h|--help)
        echo "Usage: ./verify.sh [--live]"
        exit 0
        ;;
    *)
        echo "Unknown option: $1" >&2
        echo "Usage: ./verify.sh [--live]" >&2
        exit 2
        ;;
esac

if [ "$#" -gt 1 ]; then
    echo "Usage: ./verify.sh [--live]" >&2
    exit 2
fi

if ! command -v swift-complexity >/dev/null 2>&1; then
    echo "swift-complexity is required." >&2
    echo "Install it with: brew install fummicc1/tap/swift-complexity" >&2
    exit 127
fi

echo "Release build (warnings are errors)"
swift build -c release -Xswiftc -warnings-as-errors

echo "Tests (warnings are errors)"
swift test -Xswiftc -warnings-as-errors

echo "Cognitive complexity (maximum 15)"
swift-complexity Sources --cognitive-only --threshold 15 --recursive

echo "Patch whitespace"
git diff --check

if [ "$LIVE" -eq 1 ]; then
    echo "Live provider smoke test"
    swift run -c release Tachyon --smoke
fi

echo "Verification passed"
