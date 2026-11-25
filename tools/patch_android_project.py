"""Idempotent Android platform scaffolding patch; use generated Flutter project."""
from pathlib import Path
import re
import xml.etree.ElementTree as ET

ANDROID_URI = "http://schemas.android.com/apk/res/android"
ANDROID = "{" + ANDROID_URI + "}"
VPN_SERVICE = "com.wireguard.android.backend.GoBackend$VpnService"
UPDATE_PROVIDER = "shop.pushok.flow.UpdateFileProvider"
UPDATE_INSTALL_RECEIVER = "shop.pushok.flow.UpdateInstallReceiver"
UPDATE_REPLACED_RECEIVER = "shop.pushok.flow.UpdateReplacedReceiver"
UPDATE_FOREGROUND_SERVICE = "androidx.work.impl.foreground.SystemForegroundService"
QR_ACTIVITY = "shop.pushok.flow.WireGuardQrActivity"
XRAY_SERVICE = "shop.pushok.flow.XrayVpnService"
MAIN_ACTIVITY = "shop.pushok.flow.MainActivity"
TOOLS_URI = "http://schemas.android.com/tools"
NATIVE_PACKAGING_START = "// BEGIN PUSHOK_NATIVE_PACKAGING"
NATIVE_PACKAGING_END = "// END PUSHOK_NATIVE_PACKAGING"
NATIVE_PACKAGING = f'''{NATIVE_PACKAGING_START}
// GitHub distributes standalone APKs directly; compress all native libraries.
// AGP also sets extractNativeLibs so Android installs the libraries for this device.
android {{
    packaging {{
        jniLibs {{
            useLegacyPackaging = true
            // WireGuard also ships x86, which Flutter release does not support.
            // With --split-per-abi Flutter skips its default NDK ABI filter, and
            // AGP's universal output otherwise includes that dependency ABI.
            // Exclude only x86 at packaging time; ndk.abiFilters conflicts with splits.
            excludes += "lib/x86/**"
        }}
    }}
    // --split-per-abi enables splitting in Flutter before the app DSL is read.
    // Keep the universal fallback in that same build; normal/debug builds stay unsplit.
    splits {{
        abi {{
            isUniversalApk = true
        }}
    }}
}}
{NATIVE_PACKAGING_END}'''


def patch_native_packaging(gradle: str) -> str:
    """Keep one owned Gradle block; preserve generated and user build settings."""
    start_count = gradle.count(NATIVE_PACKAGING_START)
    end_count = gradle.count(NATIVE_PACKAGING_END)
    if start_count != end_count or start_count > 1:
        raise ValueError("Invalid Pushok native packaging block")
    if start_count:
        pattern = (rf'(?ms)^{re.escape(NATIVE_PACKAGING_START)}\n.*?'
                   rf'^{re.escape(NATIVE_PACKAGING_END)}(?=\n|$)')
        gradle, changed = re.subn(pattern, lambda _: NATIVE_PACKAGING, gradle)
        if changed != 1:
            raise ValueError("Invalid Pushok native packaging block boundaries")
        return gradle
    return gradle.rstrip() + "\n\n" + NATIVE_PACKAGING + "\n"


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

    app.set(ANDROID + "icon", "@mipmap/flow_launcher")
    app.set(ANDROID + "roundIcon", "@mipmap/flow_launcher")

    # A custom link opens an import draft in our existing Activity. Flutter's router
    # must not receive the bearer URL as an initial route before native validation.
    main_activities = [item for item in app.findall("activity")
                       if item.get(ANDROID + "name") in (MAIN_ACTIVITY, ".MainActivity", "MainActivity")]
    if len(main_activities) != 1:
        raise ValueError("Subscription links require exactly one MainActivity")
    main_activity = main_activities[0]
    main_activity.set(ANDROID + "exported", "true")
    main_activity.set(ANDROID + "launchMode", "singleTop")
    for metadata in list(main_activity.findall("meta-data")):
        if metadata.get(ANDROID + "name") == "flutter_deeplinking_enabled":
            main_activity.remove(metadata)
    ET.SubElement(main_activity, "meta-data", {
        ANDROID + "name": "flutter_deeplinking_enabled", ANDROID + "value": "false",
    })
    for intent_filter in list(main_activity.findall("intent-filter")):
        if any(item.get(ANDROID + "scheme") == "pushokflow" for item in intent_filter.findall("data")):
            main_activity.remove(intent_filter)
    subscription_filter = ET.SubElement(main_activity, "intent-filter")
    ET.SubElement(subscription_filter, "action", {ANDROID + "name": "android.intent.action.VIEW"})
    ET.SubElement(subscription_filter, "category", {ANDROID + "name": "android.intent.category.DEFAULT"})
    ET.SubElement(subscription_filter, "category", {ANDROID + "name": "android.intent.category.BROWSABLE"})
    ET.SubElement(subscription_filter, "data", {
        ANDROID + "scheme": "pushokflow", ANDROID + "host": "subscription",
    })

    # The WireGuard AAR contributes its VPN service via manifest merging.
    # Remove old app declarations, including self-closing service elements.
    for service in app.findall("service"):
        if service.get(ANDROID + "name") == VPN_SERVICE:
            app.remove(service)

    # Self-updates still require Android's per-source install authorization.
    for permission_name in ("android.permission.INTERNET", "android.permission.REQUEST_INSTALL_PACKAGES",
                            "android.permission.UPDATE_PACKAGES_WITHOUT_USER_ACTION",
                            "android.permission.CAMERA", "android.permission.ACCESS_NETWORK_STATE",
                            "android.permission.CHANGE_NETWORK_STATE",
                            "android.permission.FOREGROUND_SERVICE",
                            "android.permission.FOREGROUND_SERVICE_DATA_SYNC",
                            "android.permission.POST_NOTIFICATIONS",
                            "android.permission.FOREGROUND_SERVICE_SPECIAL_USE"):
        if not any(permission.get(ANDROID + "name") == permission_name
                   for permission in manifest.findall("uses-permission")):
            permission = ET.Element("uses-permission", {ANDROID + "name": permission_name})
            manifest.insert(list(manifest).index(app), permission)

    # WorkManager owns APK transfers while the Activity is backgrounded/destroyed.
    foreground_services = [item for item in app.findall("service")
                           if item.get(ANDROID + "name") == UPDATE_FOREGROUND_SERVICE]
    foreground = foreground_services[0] if foreground_services else ET.SubElement(app, "service")
    for duplicate in foreground_services[1:]:
        app.remove(duplicate)
    foreground.clear()
    foreground.set(ANDROID + "name", UPDATE_FOREGROUND_SERVICE)
    foreground.set(ANDROID + "exported", "false")
    foreground.set(ANDROID + "foregroundServiceType", "dataSync")
    foreground.set("{" + TOOLS_URI + "}node", "merge")

    for service in app.findall("service"):
        if service.get(ANDROID + "name") in (XRAY_SERVICE, ".XrayVpnService", "XrayVpnService"):
            app.remove(service)

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

    # The installer callback is explicit; only Android can deliver the protected
    # package-replaced event. Keep both in the coordinator's default process.
    for name, action in ((UPDATE_INSTALL_RECEIVER, None),
                         (UPDATE_REPLACED_RECEIVER, "android.intent.action.MY_PACKAGE_REPLACED")):
        short_name = name.rsplit(".", 1)[1]
        receivers = [item for item in app.findall("receiver")
                     if item.get(ANDROID + "name") in (name, "." + short_name, short_name)]
        receiver = receivers[0] if receivers else ET.SubElement(app, "receiver")
        for duplicate in receivers[1:]:
            app.remove(duplicate)
        receiver.clear()
        receiver.set(ANDROID + "name", name)
        receiver.set(ANDROID + "exported", "false")
        if action is not None:
            intent_filter = ET.SubElement(receiver, "intent-filter")
            ET.SubElement(intent_filter, "action", {ANDROID + "name": action})

    for tag, name in (("receiver", "shop.pushok.flow.FlowWidget"),
                      ("activity", "shop.pushok.flow.WidgetControlActivity")):
        element = next((e for e in app.findall(tag) if e.get(ANDROID + "name") == name), None)
        if element is None:
            element = ET.SubElement(app, tag)
        element.clear()
        element.set(ANDROID + "name", name)
        element.set(ANDROID + "exported", "false")
        if tag == "receiver":
            intent = ET.SubElement(element, "intent-filter")
            ET.SubElement(intent, "action", {ANDROID + "name": "android.appwidget.action.APPWIDGET_UPDATE"})
            ET.SubElement(element, "meta-data", {ANDROID + "name": "android.appwidget.provider",
                                                 ANDROID + "resource": "@xml/flow_widget"})
        else:
            element.set(ANDROID + "theme", "@style/FlowQuickControl")
            element.set(ANDROID + "configChanges", "orientation|screenSize|keyboardHidden")
            element.set(ANDROID + "excludeFromRecents", "true")
            element.set(ANDROID + "taskAffinity", "shop.pushok.flow.widget")

    tile_name = "shop.pushok.flow.FlowTile"
    tile = next((s for s in app.findall("service") if s.get(ANDROID + "name") == tile_name), None)
    if tile is None:
        tile = ET.SubElement(app, "service")
    tile.clear()
    for attribute, value in {"name": tile_name, "exported": "true",
                             "icon": "@drawable/ic_flow_tunnel", "label": "Pushok Flow",
                             "permission": "android.permission.BIND_QUICK_SETTINGS_TILE"}.items():
        tile.set(ANDROID + attribute, value)
    tile_filter = ET.SubElement(tile, "intent-filter")
    ET.SubElement(tile_filter, "action", {ANDROID + "name": "android.service.quicksettings.action.QS_TILE"})

    push = next((service for service in app.findall("service")
                 if service.get(ANDROID + "name") == "shop.pushok.flow.FlowPush"), None)
    if push is None:
        push = ET.SubElement(app, "service")
    push.clear()
    push.set(ANDROID + "name", "shop.pushok.flow.FlowPush")
    push.set(ANDROID + "exported", "false")
    event_filter = ET.SubElement(push, "intent-filter")
    ET.SubElement(event_filter, "action", {ANDROID + "name": "com.google.firebase.MESSAGING_EVENT"})

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

    query = manifest.find("queries")
    if not any(data.get(ANDROID + "scheme") == "tg" for data in query.findall("intent/data")):
        telegram = ET.SubElement(query, "intent")
        ET.SubElement(telegram, "action", {ANDROID + "name": "android.intent.action.VIEW"})
        ET.SubElement(telegram, "data", {ANDROID + "scheme": "tg"})

    # Keystore keys cannot be restored: enforce this even for older scaffolds
    # which explicitly enabled Android Auto Backup.
    app.set(ANDROID + "name", "shop.pushok.flow.FlowPushApplication")
    app.set(ANDROID + "allowBackup", "false")
    app.set(ANDROID + "label", "Pushok Flow")
    # AGP's useLegacyPackaging owns the merged extraction flag. A stale source
    # manifest override could otherwise make compressed libraries unloadable.
    app.attrib.pop(ANDROID + "extractNativeLibs", None)
    ET.indent(tree, space="    ")
    path.write_text(ET.tostring(manifest, encoding="unicode") + "\n", encoding="utf-8")


def patch_project(root: Path) -> None:
    gradle = root / "android/app/build.gradle.kts"
    if not gradle.exists():
        raise SystemExit("Run flutter create first")
    s = gradle.read_text(encoding="utf-8")
    s = re.sub(r'(?m)^\s*implementation\(files\("libs/libXray-[^"]+\.aar"\)\)\s*$', "", s)
    for dep in ('implementation("com.wireguard.android:tunnel:1.0.20260102")',
                'implementation("com.google.firebase:firebase-messaging:24.1.2")',
                'implementation("androidx.core:core:1.17.0")',
                'implementation("androidx.work:work-runtime:2.11.2")',
                'implementation("com.journeyapps:zxing-android-embedded:4.3.0")',
                'implementation("com.google.zxing:core:3.5.4")'):
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
    s = patch_native_packaging(s)
    gradle.write_text(s, encoding="utf-8")
    patch_manifest(root / "android/app/src/main/AndroidManifest.xml")


if __name__ == "__main__":
    patch_project(Path(__file__).resolve().parents[1])
