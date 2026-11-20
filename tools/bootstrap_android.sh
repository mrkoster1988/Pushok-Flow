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
cp native/android/app/src/main/kotlin/shop/pushok/flow/{MainActivity.kt,WireGuardRouting.kt,SecureWireGuardStore.kt,LocalDecisionMemory.kt,TunnelHealth.kt,AppUpdates.kt,UpdatePolicy.kt} android/app/src/main/kotlin/shop/pushok/flow/
mkdir -p android/app/src/main/res
cp -a native/android/app/src/main/res/. android/app/src/main/res/
# flutter create --org shop.pushok --project-name pushok_flow generates a stub
# in shop/pushok/pushok_flow. Remove it: one launcher Activity only.
rm -f android/app/src/main/kotlin/shop/pushok/pushok_flow/MainActivity.kt
python3 tools/patch_android_project.py
