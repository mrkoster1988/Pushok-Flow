#!/usr/bin/env bash
# Generate Flutter Android scaffolding then integrate Pushok native code.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ ! -f android/app/build.gradle.kts ]]; then
  flutter create --platforms=android --org shop.pushok --project-name pushok_flow .
fi
mkdir -p android/app/src/main/kotlin/shop/pushok/flow
cp native/android/app/src/main/kotlin/shop/pushok/flow/{MainActivity.kt,WireGuardRouting.kt,SecureWireGuardStore.kt,LocalDecisionMemory.kt,TunnelHealth.kt} android/app/src/main/kotlin/shop/pushok/flow/
# flutter create --org shop.pushok --project-name pushok_flow generates a stub
# in shop/pushok/pushok_flow. Remove it: one launcher Activity only.
rm -f android/app/src/main/kotlin/shop/pushok/pushok_flow/MainActivity.kt
python3 tools/patch_android_project.py