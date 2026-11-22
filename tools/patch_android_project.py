"""Idempotent Android platform scaffolding patch; use generated Flutter project."""
from pathlib import Path
import re
import xml.etree.ElementTree as ET

ANDROID_URI = "http://schemas.android.com/apk/res/android"
ANDROID = "{" + ANDROID_URI + "}"
VPN_SERVICE = "com.wireguard.android.backend.GoBackend$VpnService"
UPDATE_PROVIDER = "shop.pushok.flow.UpdateFileProvider"
QR_ACTIVITY = "shop.pushok.flow.WireGuardQrActivity"
XRAY_SERVICE = "shop.pushok.flow.XrayVpnService"
TOOLS_URI = "http://schemas.android.com/tools"


def patch_manifest(path: Path) -> None:
    # Preserve namespace prefixes and Flutter's explanatory comments when writing XML.
    for _, (prefix, uri) in ET.iterparse(path, events=("start-ns",)):
        ET.register_namespace(prefix, uri)
    ET.register_namespace("tools", TOOLS_URI)
    parser = ET.XMLParser(target=ET.TreeBuilder(insert_comments=True))
    tree = ET.parse(path, parser=parser)
    manifest = tree.getroot()
    app = manifest.find("application")
    if app is None:
        raise ValueError("Android manifest has no application element")

    # The WireGuard AAR contributes its VPN service via manifest merging.
    # Remove old app declarations, including self-closing service elements.
    for service in app.findall("service"):
        if service.get(ANDROID + "name") == VPN_SERVICE:
            app.remove(service)

    # VPN/update downloads and Android's user-confirmed package installer.
    for permission_name in ("android.permission.INTERNET", "android.permission.REQUEST_INSTALL_PACKAGES",
                            "android.permission.CAMERA", "android.permission.ACCESS_NETWORK_STATE",
                            "android.permission.FOREGROUND_SERVICE",
                            "android.permission.FOREGROUND_SERVICE_SPECIAL_USE"):
        if not any(permission.get(ANDROID + "name") == permission_name
                   for permission in manifest.findall("uses-permission")):
            permission = ET.Element("uses-permission", {ANDROID + "name": permission_name})
            manifest.insert(list(manifest).index(app), permission)

    xray_services = [item for item in app.findall("service")
                     if item.get(ANDROID + "name") in (XRAY_SERVICE, ".XrayVpnService", "XrayVpnService")]
    xray = xray_services[0] if xray_services else ET.SubElement(app, "service")
    for duplicate in xray_services[1:]:
        app.remove(duplicate)
    xray.clear()
    xray.set(ANDROID + "name", XRAY_SERVICE)
    xray.set(ANDROID + "exported", "false")
    xray.set(ANDROID + "permission", "android.permission.BIND_VPN_SERVICE")
    xray.set(ANDROID + "process", ":xray")
    xray.set(ANDROID + "foregroundServiceType", "specialUse")
    intent = ET.SubElement(xray, "intent-filter")
    ET.SubElement(intent, "action", {ANDROID + "name": "android.net.VpnService"})
    ET.SubElement(xray, "property", {
        ANDROID + "name": "android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE",
        ANDROID + "value": "User initiated encrypted VLESS tunnel with per-app routing",
    })
    ET.SubElement(xray, "meta-data", {
        ANDROID + "name": "android.net.VpnService.SUPPORTS_ALWAYS_ON", ANDROID + "value": "false",
    })

    # Scanning is optional: importing a file/image and the rest of the app also work without a camera.
    for feature_name in ("android.hardware.camera", "android.hardware.camera.any",
                         "android.hardware.camera.front", "android.hardware.camera.autofocus",
                         "android.hardware.camera.flash"):
        features = [item for item in manifest.findall("uses-feature")
                    if item.get(ANDROID + "name") == feature_name]
        feature = features[0] if features else ET.Element("uses-feature")
        if not features:
            manifest.insert(list(manifest).index(app), feature)
        for duplicate in features[1:]:
            manifest.remove(duplicate)
        feature.set(ANDROID + "name", feature_name)
        feature.set(ANDROID + "required", "false")

    scanners = [item for item in app.findall("activity")
                if item.get(ANDROID + "name") in (QR_ACTIVITY, ".WireGuardQrActivity", "WireGuardQrActivity")]
    scanner = scanners[0] if scanners else ET.SubElement(app, "activity")
    for duplicate in scanners[1:]:
        app.remove(duplicate)
    scanner.set(ANDROID + "name", QR_ACTIVITY)
    scanner.set(ANDROID + "exported", "false")
    scanner.set(ANDROID + "excludeFromRecents", "true")
    scanner.set(ANDROID + "launchMode", "standard")
    scanner.set(ANDROID + "configChanges", "orientation|screenSize|keyboardHidden")
    scanner.set(ANDROID + "theme", "@android:style/Theme.Material.NoActionBar")
    scanner.attrib.pop(ANDROID + "screenOrientation", None)
    for intent_filter in scanner.findall("intent-filter"):
        scanner.remove(intent_filter)

    # The SDK's generic scanner is unused. Only the protected editor-owned Activity may scan.
    generic_name = "com.journeyapps.barcodescanner.CaptureActivity"
    generics = [item for item in app.findall("activity") if item.get(ANDROID + "name") == generic_name]
    generic = generics[0] if generics else ET.SubElement(app, "activity")
    for duplicate in generics[1:]:
        app.remove(duplicate)
    generic.clear()
    generic.set(ANDROID + "name", generic_name)
    generic.set("{" + TOOLS_URI + "}node", "remove")

    providers = [provider for provider in app.findall("provider")
                 if provider.get(ANDROID + "name") == UPDATE_PROVIDER]
    provider = providers[0] if providers else ET.SubElement(app, "provider")
    for duplicate in providers[1:]:
        app.remove(duplicate)
    provider.set(ANDROID + "name", UPDATE_PROVIDER)
    provider.set(ANDROID + "authorities", "${applicationId}.updates")
    provider.set(ANDROID + "exported", "false")
    provider.set(ANDROID + "grantUriPermissions", "true")
    path_metadata = next((item for item in provider.findall("meta-data")
                          if item.get(ANDROID + "name") == "android.support.FILE_PROVIDER_PATHS"), None)
    if path_metadata is None:
        path_metadata = ET.SubElement(provider, "meta-data")
    path_metadata.set(ANDROID + "name", "android.support.FILE_PROVIDER_PATHS")
    path_metadata.set(ANDROID + "resource", "@xml/update_paths")

    # Flutter already adds PROCESS_TEXT queries. Merge launcher visibility into
    # that block rather than treating any existing queries as sufficient.
    queries = manifest.findall("queries")
    has_launcher_query = any(
        any(action.get(ANDROID + "name") == "android.intent.action.MAIN"
            for action in intent.findall("action"))
        and any(category.get(ANDROID + "name") == "android.intent.category.LAUNCHER"
                for category in intent.findall("category"))
        for query in queries for intent in query.findall("intent")
    )
    if not has_launcher_query:
        query = queries[0] if queries else ET.SubElement(manifest, "queries")
        intent = ET.SubElement(query, "intent")
        ET.SubElement(intent, "action", {ANDROID + "name": "android.intent.action.MAIN"})
        ET.SubElement(intent, "category", {ANDROID + "name": "android.intent.category.LAUNCHER"})

    # Keystore keys cannot be restored: enforce this even for older scaffolds
    # which explicitly enabled Android Auto Backup.
    app.set(ANDROID + "allowBackup", "false")
    app.set(ANDROID + "label", "Pushok Flow")
    ET.indent(tree, space="    ")
    path.write_text(ET.tostring(manifest, encoding="unicode") + "\n", encoding="utf-8")


def patch_project(root: Path) -> None:
    gradle = root / "android/app/build.gradle.kts"
    if not gradle.exists():
        raise SystemExit("Run flutter create first")
    s = gradle.read_text(encoding="utf-8")
    for dep in ('implementation("com.wireguard.android:tunnel:1.0.20260102")',
                'implementation("androidx.core:core:1.17.0")',
                'implementation("com.journeyapps:zxing-android-embedded:4.3.0")',
                'implementation("com.google.zxing:core:3.5.4")',
                'implementation(files("libs/libXray-v26.11.9.aar"))'):
        if dep not in s:
            if re.search(r"dependencies\s*\{", s):
                s = re.sub(r"dependencies\s*\{", lambda m: m.group(0) + "\n    " + dep, s, count=1)
            else:
                s += "\ndependencies {\n    " + dep + "\n}\n"
    # Stable application ID and Kotlin namespace must match the bundled Activity.
    # Keep the app ID independent of the generated project name.
    s = re.sub(r'namespace\s*=\s*"[^"]+"', 'namespace = "shop.pushok.flow"', s)
    s = re.sub(r'applicationId\s*=\s*"[^"]+"', 'applicationId = "shop.pushok.flow"', s)
    if 'namespace = "shop.pushok.flow"' not in s or 'applicationId = "shop.pushok.flow"' not in s:
        raise SystemExit("Cannot establish Android namespace/applicationId")
    gradle.write_text(s, encoding="utf-8")
    patch_manifest(root / "android/app/src/main/AndroidManifest.xml")


if __name__ == "__main__":
    patch_project(Path(__file__).resolve().parents[1])
