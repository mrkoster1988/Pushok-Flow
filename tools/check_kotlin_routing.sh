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
  native/android/tests/UpdatePolicyCheck.kt native/android/tests/UpdateReleaseNotesCheck.kt \
  -include-runtime -d "$out/update-tests.jar"
java -cp "$out/update-tests.jar" shop.pushok.flow.UpdatePolicyCheckKt
java -cp "$out/update-tests.jar" shop.pushok.flow.UpdateReleaseNotesCheckKt
kotlinc native/android/app/src/main/kotlin/shop/pushok/flow/UpdatePolicy.kt \
  native/android/tests/UpdateAbiPolicyCheck.kt -include-runtime -d "$out/update-abi-tests.jar"
java -jar "$out/update-abi-tests.jar"
kotlinc native/android/app/src/main/kotlin/shop/pushok/flow/UpdatePolicy.kt \
  native/android/app/src/main/kotlin/shop/pushok/flow/UpdateAutomationPolicy.kt \
  native/android/tests/UpdateAutomationPolicyCheck.kt -include-runtime -d "$out/update-automation-tests.jar"
java -jar "$out/update-automation-tests.jar"
kotlinc native/android/app/src/main/kotlin/shop/pushok/flow/UpdatePolicy.kt \
  native/android/app/src/main/kotlin/shop/pushok/flow/UpdateAutomationPolicy.kt \
  native/android/app/src/main/kotlin/shop/pushok/flow/UpdateWorker.kt \
  native/android/tests/update_stubs/*.kt native/android/tests/UpdateWorkerCheck.kt \
  -nowarn -include-runtime -d "$out/update-worker-tests.jar"
java -jar "$out/update-worker-tests.jar"
kotlinc native/android/app/src/main/kotlin/shop/pushok/flow/FlowShopBridgePolicy.kt \
  native/android/tests/FlowShopBridgePolicyCheck.kt -include-runtime -d "$out/shop-bridge-policy-tests.jar"
java -jar "$out/shop-bridge-policy-tests.jar"
kotlinc native/android/app/src/main/kotlin/shop/pushok/flow/FlowAccountPolicy.kt \
  native/android/app/src/main/kotlin/shop/pushok/flow/FlowAccountSessionManager.kt \
  native/android/tests/FlowAccountCheck.kt -include-runtime -d "$out/account-tests.jar"
java -jar "$out/account-tests.jar"

kotlinc native/android/app/src/main/kotlin/shop/pushok/flow/FlowAccountPolicy.kt \
  native/android/app/src/main/kotlin/shop/pushok/flow/FlowAccountSessionManager.kt \
  native/android/app/src/main/kotlin/shop/pushok/flow/FlowAccount.kt \
  native/android/app/src/main/kotlin/shop/pushok/flow/FlowShopBridgePolicy.kt \
  native/android/tests/account_bridge_stubs/*.kt \
  native/android/tests/FlowAccountBridgeCheck.kt -include-runtime -d "$out/account-bridge-tests.jar"
java -jar "$out/account-bridge-tests.jar"

kotlinc native/android/app/src/main/kotlin/shop/pushok/flow/BoundedNetworkCall.kt \
  native/android/app/src/main/kotlin/shop/pushok/flow/FlowAccountPolicy.kt \
  native/android/app/src/main/kotlin/shop/pushok/flow/FlowAccountSessionManager.kt \
  native/android/app/src/main/kotlin/shop/pushok/flow/FlowAccountClient.kt \
  native/android/tests/account_transport_stubs/*.kt \
  native/android/tests/FlowAccountTransportCheck.kt -include-runtime -d "$out/account-transport-tests.jar"
java -jar "$out/account-transport-tests.jar"
kotlinc native/android/app/src/main/kotlin/shop/pushok/flow/ProfileProtectionPolicy.kt \
  native/android/tests/ProfileProtectionPolicyCheck.kt -include-runtime -d "$out/profile-protection-tests.jar"
java -jar "$out/profile-protection-tests.jar"
kotlinc native/android/app/src/main/kotlin/shop/pushok/flow/ProfileImportReader.kt \
  native/android/tests/ProfileImportReaderCheck.kt -include-runtime -d "$out/profile-import-tests.jar"
java -jar "$out/profile-import-tests.jar"
kotlinc native/android/app/src/main/kotlin/shop/pushok/flow/ProfileImportReader.kt \
  native/android/app/src/main/kotlin/shop/pushok/flow/ConnectionProfile.kt \
  native/android/app/src/main/kotlin/shop/pushok/flow/VlessProfile.kt \
  native/android/tests/VlessProfileCheck.kt -include-runtime -d "$out/vless-profile-tests.jar"
java -jar "$out/vless-profile-tests.jar"
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
# Exercise the same upstream Config parser as the APK, including key/IP validation.
# Only Android's SDK level is supplied by a JVM fixture; no grammar is replaced.
wireguard_aar="$out/wireguard-tunnel.aar"
wireguard_core="$out/wireguard-tunnel.jar"
if [[ -n "${FLOW_WIREGUARD_TUNNEL_AAR:-}" ]]; then
  cp "$FLOW_WIREGUARD_TUNNEL_AAR" "$wireguard_aar"
else
  curl --fail --silent --show-error --location --retry 2 --connect-timeout 15 --max-time 90 \
    https://repo.maven.apache.org/maven2/com/wireguard/android/tunnel/1.0.20260102/tunnel-1.0.20260102.aar \
    -o "$wireguard_aar"
fi
python3 - "$wireguard_aar" "$wireguard_core" <<'WIREGUARD_CHECK'
import hashlib
from pathlib import Path
import sys
import zipfile
archive = Path(sys.argv[1])
if hashlib.sha256(archive.read_bytes()).hexdigest() != '2b9c16db026496123e4db695d26d03d1958a201096c7c4c89b21077dc70f3119':
    raise SystemExit('Pinned WireGuard tunnel 1.0.20260102 checksum mismatch')
with zipfile.ZipFile(archive) as bundle:
    Path(sys.argv[2]).write_bytes(bundle.read('classes.jar'))
WIREGUARD_CHECK
profile_import_core=(
  native/android/app/src/main/kotlin/shop/pushok/flow/ProfileImportReader.kt
  native/android/app/src/main/kotlin/shop/pushok/flow/ConnectionProfile.kt
  native/android/app/src/main/kotlin/shop/pushok/flow/VlessProfile.kt
  native/android/app/src/main/kotlin/shop/pushok/flow/SubscriptionPolicy.kt
  native/android/app/src/main/kotlin/shop/pushok/flow/SubscriptionFeed.kt
  native/android/app/src/main/kotlin/shop/pushok/flow/ManagedWireGuardFeed.kt
  native/android/app/src/main/kotlin/shop/pushok/flow/WireGuardRouting.kt
  native/android/app/src/main/kotlin/shop/pushok/flow/ProfileCatalogStore.kt
  native/android/app/src/main/kotlin/shop/pushok/flow/SubscriptionLinks.kt
  native/android/app/src/main/kotlin/shop/pushok/flow/ProfileImportPayload.kt
  native/android/tests/wireguard_runtime_stubs/AndroidBuild.kt
)
kotlinc "${profile_import_core[@]}" \
  native/android/app/src/main/kotlin/shop/pushok/flow/ProfileQrDecoder.kt \
  native/android/app/src/main/kotlin/shop/pushok/flow/ProfileQrSession.kt \
  native/android/tests/ProfileQrImportCheck.kt -classpath "$core:$wireguard_core" -include-runtime -d "$out/qr-import-tests.jar"
java -cp "$out/qr-import-tests.jar:$core:$wireguard_core" shop.pushok.flow.ProfileQrImportCheckKt

profile_import_android_stubs=()
for fixture in native/android/tests/profile_import_stubs/*.kt; do
  # The historical unused grammar stub must not shadow the real Config class.
  if [[ "$fixture" != */WireGuardConfig.kt ]]; then profile_import_android_stubs+=("$fixture"); fi
done
kotlinc "${profile_import_core[@]}" \
  native/android/app/src/main/kotlin/shop/pushok/flow/ProfileQrDecoder.kt \
  native/android/app/src/main/kotlin/shop/pushok/flow/ProfileQrSession.kt \
  native/android/app/src/main/kotlin/shop/pushok/flow/ProfileImportWork.kt \
  native/android/app/src/main/kotlin/shop/pushok/flow/WireGuardProfileImport.kt \
  "${profile_import_android_stubs[@]}" \
  native/android/tests/ProfileImportExecutionCheck.kt -classpath "$core:$wireguard_core" \
  -include-runtime -d "$out/profile-import-execution-tests.jar"
java -cp "$out/profile-import-execution-tests.jar:$core:$wireguard_core" shop.pushok.flow.ProfileImportExecutionCheckKt
embedded_aar="$out/zxing-android-embedded.aar"
embedded_core="$out/zxing-android-embedded.jar"
if [[ -n "${FLOW_ZXING_EMBEDDED_AAR:-}" ]]; then
  cp "$FLOW_ZXING_EMBEDDED_AAR" "$embedded_aar"
else
  curl --fail --silent --show-error --location --retry 2 --connect-timeout 15 --max-time 90 \
    https://repo.maven.apache.org/maven2/com/journeyapps/zxing-android-embedded/4.3.0/zxing-android-embedded-4.3.0.aar \
    -o "$embedded_aar"
fi
python3 - "$embedded_aar" "$embedded_core" <<'EMBEDDED_CHECK'
import hashlib
from pathlib import Path
import sys
import zipfile
archive = Path(sys.argv[1])
if hashlib.sha256(archive.read_bytes()).hexdigest() != '4ab03353127c34e55cbb80fbc9a34031decbcfb1ec5e8f991944d2d494621a33':
    raise SystemExit('Pinned JourneyApps ZXing embedded 4.3.0 checksum mismatch')
with zipfile.ZipFile(archive) as bundle:
    Path(sys.argv[2]).write_bytes(bundle.read('classes.jar'))
EMBEDDED_CHECK
kotlinc "${profile_import_core[@]}" \
  native/android/app/src/main/kotlin/shop/pushok/flow/ProfileQrDecoder.kt \
  native/android/app/src/main/kotlin/shop/pushok/flow/ProfileQrCameraDecoder.kt \
  native/android/tests/ProfileQrCameraCheck.kt -classpath "$core:$embedded_core:$wireguard_core" \
  -include-runtime -d "$out/qr-camera-tests.jar"
java -cp "$out/qr-camera-tests.jar:$core:$embedded_core:$wireguard_core" shop.pushok.flow.ProfileQrCameraCheckKt
subscription_core=(
  native/android/app/src/main/kotlin/shop/pushok/flow/ProfileImportReader.kt
  native/android/app/src/main/kotlin/shop/pushok/flow/ConnectionProfile.kt
  native/android/app/src/main/kotlin/shop/pushok/flow/VlessProfile.kt
  native/android/app/src/main/kotlin/shop/pushok/flow/SubscriptionPolicy.kt
  native/android/app/src/main/kotlin/shop/pushok/flow/SubscriptionFeed.kt
  native/android/app/src/main/kotlin/shop/pushok/flow/ManagedWireGuardFeed.kt
  native/android/app/src/main/kotlin/shop/pushok/flow/WireGuardRouting.kt
  native/android/app/src/main/kotlin/shop/pushok/flow/ProfileCatalogStore.kt
  native/android/tests/wireguard_runtime_stubs/AndroidBuild.kt
)
kotlinc "${subscription_core[@]}" \
  native/android/app/src/main/kotlin/shop/pushok/flow/ProfileOperationGate.kt \
  native/android/tests/ProfileCatalogCheck.kt -classpath "$wireguard_core" -include-runtime -d "$out/profile-catalog-tests.jar"
java -cp "$out/profile-catalog-tests.jar:$wireguard_core" shop.pushok.flow.ProfileCatalogCheckKt
kotlinc "${subscription_core[@]}" \
  native/android/app/src/main/kotlin/shop/pushok/flow/SubscriptionLinks.kt \
  native/android/app/src/main/kotlin/shop/pushok/flow/BoundedNetworkCall.kt \
  native/android/app/src/main/kotlin/shop/pushok/flow/SubscriptionDownloader.kt \
  native/android/tests/SubscriptionFeedCheck.kt \
  native/android/tests/ManagedWireGuardFeedCheck.kt \
  native/android/tests/SubscriptionCatalogCheck.kt \
  native/android/tests/ManagedSubscriptionCatalogCheck.kt \
  native/android/tests/SubscriptionTransportCheck.kt -classpath "$wireguard_core" -include-runtime -d "$out/subscription-tests.jar"
java -cp "$out/subscription-tests.jar:$wireguard_core" shop.pushok.flow.SubscriptionFeedCheckKt
java -cp "$out/subscription-tests.jar:$wireguard_core" shop.pushok.flow.ManagedWireGuardFeedCheckKt
java -cp "$out/subscription-tests.jar:$wireguard_core" shop.pushok.flow.SubscriptionCatalogCheckKt
java -cp "$out/subscription-tests.jar:$wireguard_core" shop.pushok.flow.ManagedSubscriptionCatalogCheckKt
java -cp "$out/subscription-tests.jar:$wireguard_core" shop.pushok.flow.SubscriptionTransportCheckKt
kotlinc "${subscription_core[@]}" \
  native/android/app/src/main/kotlin/shop/pushok/flow/SubscriptionLinks.kt \
  native/android/app/src/main/kotlin/shop/pushok/flow/BoundedNetworkCall.kt \
  native/android/app/src/main/kotlin/shop/pushok/flow/SubscriptionDownloader.kt \
  native/android/app/src/main/kotlin/shop/pushok/flow/ProfileSubscriptions.kt \
  native/android/app/src/main/kotlin/shop/pushok/flow/FlowShopBridgePolicy.kt \
  native/android/app/src/main/kotlin/shop/pushok/flow/FlowShopBindingStore.kt \
  native/android/tests/subscription_coordinator_stubs/*.kt \
  native/android/tests/SubscriptionCoordinatorCheck.kt -classpath "$wireguard_core" -include-runtime -d "$out/subscription-coordinator-tests.jar"
java -cp "$out/subscription-coordinator-tests.jar:$wireguard_core" shop.pushok.flow.SubscriptionCoordinatorCheckKt
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

kotlinc native/android/app/src/main/kotlin/shop/pushok/flow/XrayLifecycle.kt \
  native/android/tests/XrayLifecycleCheck.kt -include-runtime -d "$out/xray-lifecycle-tests.jar"
java -jar "$out/xray-lifecycle-tests.jar"

kotlinc native/android/app/src/main/kotlin/shop/pushok/flow/XrayNetworkPolicy.kt \
  native/android/tests/XrayNetworkPolicyCheck.kt -include-runtime -d "$out/xray-network-policy-tests.jar"
java -jar "$out/xray-network-policy-tests.jar"

kotlinc native/android/app/src/main/kotlin/shop/pushok/flow/XrayNetworkPolicy.kt \
  native/android/app/src/main/kotlin/shop/pushok/flow/XrayNetworkMonitor.kt \
  native/android/tests/xray_network_stubs/*.kt \
  native/android/tests/XrayNetworkMonitorCheck.kt -include-runtime -d "$out/xray-network-monitor-tests.jar"
java -jar "$out/xray-network-monitor-tests.jar"

kotlinc native/android/app/src/main/kotlin/shop/pushok/flow/XrayDnsWire.kt \
  native/android/app/src/main/kotlin/shop/pushok/flow/XrayDnsBridge.kt \
  native/android/tests/XrayDnsWireCheck.kt \
  native/android/tests/XrayDnsBridgeCheck.kt -include-runtime -d "$out/xray-dns-tests.jar"
java -cp "$out/xray-dns-tests.jar" shop.pushok.flow.XrayDnsWireCheckKt
java -cp "$out/xray-dns-tests.jar" shop.pushok.flow.XrayDnsBridgeCheckKt

kotlinc native/android/app/src/main/kotlin/shop/pushok/flow/XrayTunnelStatus.kt \
  native/android/app/src/main/kotlin/shop/pushok/flow/XrayLifecycle.kt \
  native/android/tests/XrayTunnelStatusCheck.kt -include-runtime -d "$out/xray-status-tests.jar"
java -jar "$out/xray-status-tests.jar"

json_core="$out/json-core.jar"
if [[ -n "${FLOW_JSON_CORE_JAR:-}" ]]; then
  cp "$FLOW_JSON_CORE_JAR" "$json_core"
else
  curl --fail --silent --show-error --location --retry 2 --connect-timeout 15 --max-time 90 \
    https://repo.maven.apache.org/maven2/org/json/json/20250517/json-20250517.jar -o "$json_core"
fi
python3 - "$json_core" <<'JSON_CHECK'
import hashlib
from pathlib import Path
import sys
if hashlib.sha256(Path(sys.argv[1]).read_bytes()).hexdigest() != '3ea61b2a06e31edf1c91134fe9106b0ebb16628be169f3db75bc7a2b06b45796':
    raise SystemExit('Pinned JVM JSON test library checksum mismatch')
JSON_CHECK
# Compile against the JVM generic signatures; execute Store JSON with Android's
# null-preserving JSONObject(Map) semantics instead of the different JVM variant.
android_json="$out/android-json.jar"
if [[ -n "${FLOW_ANDROID_JSON_JAR:-}" ]]; then
  cp "$FLOW_ANDROID_JSON_JAR" "$android_json"
else
  curl --fail --silent --show-error --location --retry 2 --connect-timeout 15 --max-time 90 \
    https://repo.maven.apache.org/maven2/com/vaadin/external/google/android-json/0.0.20131108.vaadin1/android-json-0.0.20131108.vaadin1.jar \
    -o "$android_json"
fi
python3 - "$android_json" <<'ANDROID_JSON_CHECK'
import hashlib
from pathlib import Path
import sys
if hashlib.sha256(Path(sys.argv[1]).read_bytes()).hexdigest() != 'dfb7bae2f404cfe0b72b4d23944698cb716b7665171812a0a4d0f5926c0fac79':
    raise SystemExit('Pinned Android JSON test library checksum mismatch')
ANDROID_JSON_CHECK
kotlinc native/android/app/src/main/kotlin/shop/pushok/flow/FlowAccountPolicy.kt \
  native/android/app/src/main/kotlin/shop/pushok/flow/FlowAccountSessionManager.kt \
  native/android/app/src/main/kotlin/shop/pushok/flow/FlowAccountStore.kt \
  native/android/tests/account_store_stubs/*.kt native/android/tests/FlowAccountStoreCheck.kt \
  -classpath "$json_core" -include-runtime -d "$out/account-store-tests.jar"
java -cp "$out/account-store-tests.jar:$android_json" shop.pushok.flow.FlowAccountStoreCheckKt
kotlinc "${subscription_core[@]}" \
  native/android/app/src/main/kotlin/shop/pushok/flow/SecureWireGuardStore.kt \
  native/android/tests/account_store_stubs/*.kt native/android/tests/SecureWireGuardStoreCheck.kt \
  -classpath "$json_core:$wireguard_core" -include-runtime -d "$out/profile-store-tests.jar"
java -cp "$out/profile-store-tests.jar:$android_json:$wireguard_core" shop.pushok.flow.SecureWireGuardStoreCheckKt
kotlinc native/android/app/src/main/kotlin/shop/pushok/flow/UpdatePolicy.kt \
  native/android/app/src/main/kotlin/shop/pushok/flow/UpdateAutomationPolicy.kt \
  native/android/app/src/main/kotlin/shop/pushok/flow/UpdateCoordinator.kt \
  native/android/tests/update_coordinator_stubs/*.kt native/android/tests/UpdateCoordinatorCheck.kt \
  -classpath "$json_core" -nowarn -include-runtime -d "$out/update-coordinator-tests.jar"
java -cp "$out/update-coordinator-tests.jar:$json_core" shop.pushok.flow.UpdateCoordinatorCheckKt
kotlinc native/android/app/src/main/kotlin/shop/pushok/flow/ProfileImportReader.kt \
  native/android/app/src/main/kotlin/shop/pushok/flow/ConnectionProfile.kt \
  native/android/app/src/main/kotlin/shop/pushok/flow/VlessProfile.kt \
  native/android/app/src/main/kotlin/shop/pushok/flow/XrayConfig.kt \
  native/android/tests/XrayConfigCheck.kt -classpath "$json_core" -include-runtime -d "$out/xray-config-tests.jar"
java -cp "$out/xray-config-tests.jar:$json_core" shop.pushok.flow.XrayConfigCheckKt
