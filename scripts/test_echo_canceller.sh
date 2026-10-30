#!/usr/bin/env bash
# Builds the echo canceller archive and runs the production writer on a
# simulated speaker echo. Needs meson and ninja, but no audio device,
# permission, Xcode project or network after the first abseil download.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

"$ROOT/scripts/build_echo_canceller.sh"

# Top-level test code must be in a file named main.swift.
cp "$ROOT/scripts/test_echo_canceller.swift" "$OUT/main.swift"
swiftc -O -o "$OUT/test_echo_canceller" \
  -import-objc-header "$ROOT/src/native/echo_canceller.h" \
  -L "$ROOT/build" -lecho_canceller -lc++ \
  "$ROOT/src/client/EchoCancellation.swift" \
  "$OUT/main.swift" 2>&1 | grep -v "^ld: warning: .*was built for newer" || true
[ -x "$OUT/test_echo_canceller" ] || exit 1

echo "== Echo canceller, simulated speaker echo =="
"$OUT/test_echo_canceller" "$ROOT/jfk.wav"
