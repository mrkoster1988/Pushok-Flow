#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
root="$PWD/.build"
source_dir="$root/wireguard-apple"
revision=2fec12a6e1f6e3460b6ee483aa00ad29cddadab1
mkdir -p "$root/parser" "$root/bridge"
if [[ ! -d "$source_dir/.git" ]]; then
  git clone --depth 1 --branch 1.0.16-27 https://github.com/WireGuard/wireguard-apple.git "$source_dir"
fi
[[ "$(git -C "$source_dir" rev-parse HEAD)" == "$revision" ]]
# The pinned manifest uses platform constants introduced in PackageDescription 5.5.
git -C "$source_dir" show HEAD:Package.swift | sed '1s/swift-tools-version:5.3/swift-tools-version:5.5/' > "$source_dir/Package.swift"
# WireGuardKit's wg-quick parser ships with the upstream app, outside the Swift package.
model="$source_dir/Sources/Shared/Model"
{ echo 'import WireGuardKit'; cat "$model/TunnelConfiguration+WgQuickConfig.swift"; } > "$root/parser/WgQuick.swift"
cp "$model/String+ArrayConversion.swift" "$root/parser/"
cp "$source_dir/COPYING" "$root/WireGuard-License.txt"
make -C "$source_dir/Sources/WireGuardKitGo" ARCHS=arm64 PLATFORM_NAME=iphoneos \
  SDKROOT="$(xcrun --sdk iphoneos --show-sdk-path)" CONFIGURATION_BUILD_DIR="$root/bridge" \
  CONFIGURATION_TEMP_DIR="$root/tmp" DEPLOYMENT_TARGET_CLANG_FLAG_NAME=miphoneos-version-min \
  DEPLOYMENT_TARGET_CLANG_ENV_NAME=IPHONEOS_DEPLOYMENT_TARGET IPHONEOS_DEPLOYMENT_TARGET=16.0
swift make-icon.swift ../assets/mascot/pushok.png App/AppAssets.xcassets/AppIcon.appiconset/icon.png
version=$(sed -n 's/^version: //p' ../pubspec.yaml)
[[ "$version" =~ ^([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)$ ]]
export MARKETING_VERSION="${BASH_REMATCH[1]}" CURRENT_PROJECT_VERSION="${BASH_REMATCH[2]}"
xcodegen generate --spec project.yml
