#!/bin/bash
#
# tools/verify/run.sh — the project's verification gate.
#
# Runs everything checkable WITHOUT Xcode, so a contributor holding only the Command Line Tools
# (and any CI runner) can validate a change before it ships. Two stages, both must pass:
#
#   1. Typecheck every app source file, using the same language mode the Xcode project builds with
#      (Swift 5 + SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor — see project.pbxproj:298-301). Getting
#      that isolation flag right is load-bearing: without it the compiler reports dozens of bogus
#      "main actor-isolated property referenced from a nonisolated context" errors, because the
#      codebase relies on MainActor-by-default and marks the exceptions `nonisolated` by hand.
#   2. Build and run the liveness/decision self-tests against the real Liveness sources.
#
# Two substitutions make stage 1 possible, neither of which reaches the app target:
#   - `Updater/` is swapped for SparkleStub.swift (Sparkle is a SwiftPM dep swiftc can't resolve).
#   - `#Preview` blocks are truncated from a scratch copy of the sources, and `@Entry` is expanded
#     by hand into the EnvironmentKey + accessor pair it generates. Both macros' plugins ship with
#     Xcode, not the CLT. Every #Preview in this project sits at end-of-file, so cutting from the
#     first one preserves all real code above it.
#
# Usage: ./tools/verify/run.sh
#
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

SDK="$(xcrun --show-sdk-path --sdk macosx)"
TARGET="arm64-apple-macos15.0"
MODE=(-swift-version 5 -default-isolation MainActor -enable-upcoming-feature MemberImportVisibility)
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
FAILED=0

echo "==> [1/2] Typechecking app sources"
# Mirror the tree into scratch, truncating each file at its first #Preview line.
while IFS= read -r f; do
  mkdir -p "$SCRATCH/$(dirname "$f")"
  # Truncate at the first #Preview, then hand-expand @Entry (another Xcode-only macro plugin)
  # into the EnvironmentKey + accessor pair it generates, so the file still typechecks.
  awk '/^#Preview/{exit} {print}' "$f" \
    | perl -pe 's{^(\s*)\@Entry var (\w+): ([^=]+?) = (.+)$}{$1private struct __EntryKey_$2: EnvironmentKey { static let defaultValue: $3 = $4 }\n$1var $2: $3 { get { self[__EntryKey_$2.self] } set { self[__EntryKey_$2.self] = newValue } }}' \
    > "$SCRATCH/$f"
done < <(find glance -name '*.swift' ! -path '*/Updater/*')

APP_FILES=()
while IFS= read -r f; do APP_FILES+=("$SCRATCH/$f"); done < <(find glance -name '*.swift' ! -path '*/Updater/*' | sort)
APP_FILES+=("tools/verify/SparkleStub.swift")

if swiftc -typecheck -sdk "$SDK" -target "$TARGET" "${MODE[@]}" "${APP_FILES[@]}"; then
  echo "    OK — ${#APP_FILES[@]} files typecheck clean"
else
  echo "    FAIL — typecheck errors above"; FAILED=1
fi

echo "==> [2/2] Liveness + decision self-tests"
BIN="$SCRATCH/liveness_selftest"
if swiftc -O -sdk "$SDK" -target "$TARGET" "${MODE[@]}" -o "$BIN" \
    glance/Liveness/LandmarkGeometry.swift \
    glance/Liveness/GeometryLiveness.swift \
    glance/Liveness/GlareCue.swift \
    glance/Liveness/LivenessCues.swift \
    glance/Liveness/LivenessScoring.swift \
    glance/Liveness/LivenessAnalyzer.swift \
    tools/liveness_selftest.swift 2>&1; then
  if "$BIN" > "$SCRATCH/out.txt" 2>&1; then
    echo "    OK — $(grep -c '^PASS' "$SCRATCH/out.txt") self-tests passed"
  else
    echo "    FAIL — self-tests failed:"; cat "$SCRATCH/out.txt"; FAILED=1
  fi
else
  echo "    FAIL — self-test build errors above"; FAILED=1
fi

echo
if [ "$FAILED" -eq 0 ]; then echo "VERIFY PASSED"; else echo "VERIFY FAILED"; fi
exit "$FAILED"
