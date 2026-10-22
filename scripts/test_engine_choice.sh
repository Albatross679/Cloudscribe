#!/usr/bin/env bash
# Engine choice and focus-click regression on the production selector source.
# Opens two small windows in this process only; it never activates, posts
# global input, or reads preferences.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
swiftc -parse-as-library -o "$OUT/test_engine_choice" \
  "$ROOT/src/client/UsageMetrics.swift" \
  "$ROOT/src/client/CloudProvider.swift" \
  "$ROOT/src/client/EngineChoiceSelector.swift" \
  "$ROOT/scripts/test_engine_choice.swift"
"$OUT/test_engine_choice"
