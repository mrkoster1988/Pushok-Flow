"""Idempotent Android platform scaffolding patch; use generated Flutter project."""
from pathlib import Path
import re
import xml.etree.ElementTree as ET

ANDROID_URI = "http://schemas.android.com/apk/res/android"
ANDROID = "{" + ANDROID_URI + "}"
VPN_SERVICE = "com.wireguard.android.backend.GoBackend$VpnService"


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

    # VPN needs INTERNET in the main manifest for both debug and release builds.
    if not any(permission.get(ANDROID + "name") == "android.permission.INTERNET"
               for permission in manifest.findall("uses-permission")):
        permission = ET.Element("uses-permission", {
            ANDROID + "name": "android.permission.INTERNET",
        })
        manifest.insert(list(manifest).index(app), permission)

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
    ET.indent(tree, space="    ")
    path.write_text(ET.tostring(manifest, encoding="unicode") + "\n", encoding="utf-8")


def patch_project(root: Path) -> None:
    gradle = root / "android/app/build.gradle.kts"
    if not gradle.exists():
        raise SystemExit("Run flutter create first")
    s = gradle.read_text(encoding="utf-8")
    dep = 'implementation("com.wireguard.android:tunnel:1.0.20260102")'
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
