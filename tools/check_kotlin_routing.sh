#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if ! command -v kotlinc >/dev/null || ! command -v java >/dev/null; then
  echo 'Kotlin CLI and Java are required for executable route checks' >&2
  exit 2
fi
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
kotlinc native/android/app/src/main/kotlin/shop/pushok/flow/WireGuardRouting.kt \
  native/android/tests/WireGuardRoutingCheck.kt -include-runtime -d "$out/routing-tests.jar"
java -jar "$out/routing-tests.jar"