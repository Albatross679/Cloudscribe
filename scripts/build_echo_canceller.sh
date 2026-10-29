#!/usr/bin/env bash
# Build build/libecho_canceller.a: the src/native C wrapper, the pinned
# webrtc-audio-processing submodule and the abseil it needs, in one static
# archive, so the app links it in and ships no extra dylib.
#
# Needs meson and ninja (brew install meson ninja). Meson downloads abseil
# through the submodule's pinned, hash-checked wrap on the first build. Later
# runs only rebuild what changed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT/webrtc-audio-processing"
OUT="$ROOT/build/echo-canceller"
ARCHIVE="$ROOT/build/libecho_canceller.a"

if [ ! -f "$SOURCE/meson.build" ]; then
  echo "Missing webrtc-audio-processing. Run: git submodule update --init" >&2
  exit 1
fi

# Match the app's deployment target, or the linker warns on every object.
export MACOSX_DEPLOYMENT_TARGET=14.0

if [ ! -f "$OUT/meson/build.ninja" ]; then
  # Use abseil from the wrap even when Homebrew has one: a Homebrew dylib
  # would make the app depend on /opt/homebrew at runtime.
  meson setup "$OUT/meson" "$SOURCE" \
    --prefix "$OUT/install" \
    -Dbuildtype=release -Db_ndebug=true \
    -Ddefault_library=static \
    --force-fallback-for=abseil-cpp
fi
ninja -C "$OUT/meson" install > "$OUT/ninja.log" || { cat "$OUT/ninja.log" >&2; exit 1; }

# The wrapper builds AEC3 itself, whose header is not installed, so it also
# reads the pinned source tree.
INCLUDE="$OUT/install/include"
clang++ -std=c++17 -O2 -arch arm64 -mmacosx-version-min="$MACOSX_DEPLOYMENT_TARGET" \
  -DWEBRTC_POSIX -DWEBRTC_MAC -DWEBRTC_APM_DEBUG_DUMP=0 \
  -I"$INCLUDE/webrtc-audio-processing-2" -I"$INCLUDE" -I"$SOURCE/webrtc" \
  -c "$ROOT/src/native/echo_canceller.cc" -o "$OUT/echo_canceller.o"

# The installed archive leaves abseil symbols undefined; abseil's own archives
# are only in the meson build tree.
ABSEIL=("$OUT"/meson/subprojects/abseil-cpp-*/libabsl_*.a)
if [ ! -f "${ABSEIL[0]}" ]; then
  echo "No abseil archives under $OUT/meson/subprojects" >&2
  exit 1
fi
rm -f "$ARCHIVE"
libtool -static -no_warning_for_no_symbols -o "$ARCHIVE" \
  "$OUT/echo_canceller.o" "$OUT/install/lib/libwebrtc-audio-processing-2.a" "${ABSEIL[@]}" \
  2> >(grep -v "same member name" >&2)

echo "Built $ARCHIVE"
