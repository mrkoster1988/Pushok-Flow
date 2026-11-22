#!/usr/bin/env bash
# Generate Flutter Android scaffolding then integrate Pushok native code.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ ! -f android/app/build.gradle.kts ]]; then
  # Generate away from the app: flutter create also writes Dart templates,
  # counter tests and analysis options which do not belong in this project.
  scaffold_dir="$(mktemp -d "${TMPDIR:-/tmp}/pushok-flow-android.XXXXXX")"
  trap 'rm -rf -- "$scaffold_dir"' EXIT
  flutter create --no-pub --platforms=android --org shop.pushok \
    --project-name pushok_flow "$scaffold_dir/project"
  mkdir -p android
  cp -a "$scaffold_dir/project/android/." android/
fi
mkdir -p android/app/src/main/kotlin/shop/pushok/flow
cp native/android/app/src/main/kotlin/shop/pushok/flow/{MainActivity.kt,WireGuardRouting.kt,ConnectionProfile.kt,VlessProfile.kt,XrayConfig.kt,XrayLifecycle.kt,XrayTunnelClient.kt,XrayVpnService.kt,SecureWireGuardStore.kt,LocalDecisionMemory.kt,TunnelHealth.kt,TunnelConnectionSession.kt,AppUpdates.kt,FlowAccount.kt,FlowAccountPolicy.kt,FlowAccountSessionManager.kt,FlowAccountStore.kt,FlowAccountClient.kt,UpdatePolicy.kt,UpdateCoordinator.kt,UpdateWorker.kt,UpdateInstallReceiver.kt,UpdateReplacedReceiver.kt,UpdateAutomationPolicy.kt,ProfileScreenProtection.kt,ProfileProtectionPolicy.kt,WireGuardProfileImport.kt,ProfileImportReader.kt,ProfileQrDecoder.kt,ProfileQrCameraDecoder.kt,ProfileQrImageReader.kt,ProfileQrSession.kt,WireGuardQrActivity.kt,ProfileCatalogStore.kt,ProfileOperationGate.kt,SubscriptionPolicy.kt,SubscriptionFeed.kt,SubscriptionLinks.kt,SubscriptionDownloader.kt,ProfileSubscriptions.kt,RouteSettingsStore.kt,RouteAppAvailability.kt,RouteRecommendationPolicy.kt,RouteRecommendationStore.kt,RecommendationAutomation.kt,RouteRecommendations.kt} android/app/src/main/kotlin/shop/pushok/flow/
mkdir -p android/app/src/main/res
cp -a native/android/app/src/main/res/. android/app/src/main/res/
if [[ -d native/android/app/src/main/assets ]]; then
  mkdir -p android/app/src/main/assets
  cp -a native/android/app/src/main/assets/. android/app/src/main/assets/
fi
# flutter create --org shop.pushok --project-name pushok_flow generates a stub
# in shop/pushok/pushok_flow. Remove it: one launcher Activity only.
rm -f android/app/src/main/kotlin/shop/pushok/pushok_flow/MainActivity.kt
python3 tools/patch_android_project.py
