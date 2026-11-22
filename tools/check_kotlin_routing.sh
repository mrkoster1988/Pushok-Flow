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
kotlinc native/android/app/src/main/kotlin/shop/pushok/flow/TunnelConnectionSession.kt \
  native/android/tests/TunnelConnectionSessionCheck.kt -include-runtime -d "$out/connection-session-tests.jar"
java -jar "$out/connection-session-tests.jar"
kotlinc native/android/app/src/main/kotlin/shop/pushok/flow/UpdatePolicy.kt \
  native/android/tests/UpdatePolicyCheck.kt -include-runtime -d "$out/update-tests.jar"
java -jar "$out/update-tests.jar"
kotlinc native/android/app/src/main/kotlin/shop/pushok/flow/ProfileProtectionPolicy.kt \
  native/android/tests/ProfileProtectionPolicyCheck.kt -include-runtime -d "$out/profile-protection-tests.jar"
java -jar "$out/profile-protection-tests.jar"
kotlinc native/android/app/src/main/kotlin/shop/pushok/flow/ProfileImportReader.kt \
  native/android/tests/ProfileImportReaderCheck.kt -include-runtime -d "$out/profile-import-tests.jar"
java -jar "$out/profile-import-tests.jar"
core="$out/zxing-core.jar"
if [[ -n "${FLOW_ZXING_CORE_JAR:-}" ]]; then
  cp "$FLOW_ZXING_CORE_JAR" "$core"
else
  curl --fail --silent --show-error --location --retry 2 --connect-timeout 15 --max-time 90 \
    https://repo.maven.apache.org/maven2/com/google/zxing/core/3.5.4/core-3.5.4.jar -o "$core"
fi
python3 - "$core" <<'PY'
import hashlib
from pathlib import Path
import sys
expected = '71de5d89341b5fcf5dd89da7f44e84d825d0e084cdf3ec77c9abe26b0f0ceb13'
if hashlib.sha256(Path(sys.argv[1]).read_bytes()).hexdigest() != expected:
    raise SystemExit('The pinned ZXing core 3.5.4 checksum does not match')
PY
kotlinc native/android/app/src/main/kotlin/shop/pushok/flow/ProfileImportReader.kt \
  native/android/app/src/main/kotlin/shop/pushok/flow/ProfileQrDecoder.kt \
  native/android/app/src/main/kotlin/shop/pushok/flow/ProfileQrSession.kt \
  native/android/tests/ProfileQrImportCheck.kt -classpath "$core" -include-runtime -d "$out/qr-import-tests.jar"
java -cp "$out/qr-import-tests.jar:$core" shop.pushok.flow.ProfileQrImportCheckKt
kotlinc native/android/app/src/main/kotlin/shop/pushok/flow/ProfileCatalogStore.kt \
  native/android/app/src/main/kotlin/shop/pushok/flow/ProfileOperationGate.kt \
  native/android/tests/ProfileCatalogCheck.kt -include-runtime -d "$out/profile-catalog-tests.jar"
java -jar "$out/profile-catalog-tests.jar"
kotlinc native/android/app/src/main/kotlin/shop/pushok/flow/RouteSettingsStore.kt \
  native/android/tests/RouteSettingsCheck.kt -include-runtime -d "$out/route-settings-tests.jar"
java -jar "$out/route-settings-tests.jar"
kotlinc native/android/app/src/main/kotlin/shop/pushok/flow/RouteSettingsStore.kt \
  native/android/app/src/main/kotlin/shop/pushok/flow/TunnelConnectionSession.kt \
  native/android/app/src/main/kotlin/shop/pushok/flow/RouteAppAvailability.kt \
  native/android/tests/RouteAppAvailabilityCheck.kt -include-runtime -d "$out/route-availability-tests.jar"
java -jar "$out/route-availability-tests.jar"
kotlinc native/android/app/src/main/kotlin/shop/pushok/flow/RouteSettingsStore.kt \
  native/android/app/src/main/kotlin/shop/pushok/flow/RouteRecommendationPolicy.kt \
  native/android/app/src/main/kotlin/shop/pushok/flow/RouteRecommendationStore.kt \
  native/android/app/src/main/kotlin/shop/pushok/flow/RecommendationAutomation.kt \
  native/android/tests/RecommendationAutomationCheck.kt \
  native/android/tests/RouteRecommendationsCheck.kt -include-runtime -d "$out/route-recommendations-tests.jar"
java -jar "$out/route-recommendations-tests.jar"
