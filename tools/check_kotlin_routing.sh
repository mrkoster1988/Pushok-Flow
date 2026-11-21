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
kotlinc native/android/app/src/main/kotlin/shop/pushok/flow/TunnelHealth.kt \
  native/android/tests/TunnelHealthCheck.kt -include-runtime -d "$out/health-tests.jar"
java -jar "$out/health-tests.jar"
kotlinc native/android/app/src/main/kotlin/shop/pushok/flow/UpdatePolicy.kt \
  native/android/tests/UpdatePolicyCheck.kt -include-runtime -d "$out/update-tests.jar"
java -jar "$out/update-tests.jar"
kotlinc native/android/app/src/main/kotlin/shop/pushok/flow/ProfileProtectionPolicy.kt \
  native/android/tests/ProfileProtectionPolicyCheck.kt -include-runtime -d "$out/profile-protection-tests.jar"
java -jar "$out/profile-protection-tests.jar"
kotlinc native/android/app/src/main/kotlin/shop/pushok/flow/ProfileImportReader.kt \
  native/android/tests/ProfileImportReaderCheck.kt -include-runtime -d "$out/profile-import-tests.jar"
java -jar "$out/profile-import-tests.jar"
