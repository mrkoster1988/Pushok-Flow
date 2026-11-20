"""Idempotent Android platform scaffolding patch; use generated Flutter project."""
from pathlib import Path
import re
import xml.etree.ElementTree as ET

ANDROID_URI = "http://schemas.android.com/apk/res/android"
ANDROID = "{" + ANDROID_URI + "}"
VPN_SERVICE = "com.wireguard.android.backend.GoBackend$VpnService"
UPDATE_PROVIDER = "shop.pushok.flow.UpdateFileProvider"


def patch_manifest(path: Path) -> None:
    # Preserve namespace prefixes and Flutter's explanatory comments when writing XML.
    for _, (prefix, uri) in ET.iterparse(path, events=("start-ns",)):
        ET.register_namespace(prefix, uri)
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
    for permission_name in ("android.permission.INTERNET", "android.permission.REQUEST_INSTALL_PACKAGES"):
        if not any(permission.get(ANDROID + "name") == permission_name
                   for permission in manifest.findall("uses-permission")):
            permission = ET.Element("uses-permission", {ANDROID + "name": permission_name})
            manifest.insert(list(manifest).index(app), permission)

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
                'implementation("androidx.core:core:1.17.0")'):
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
