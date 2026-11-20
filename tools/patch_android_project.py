"""Idempotent Android platform scaffolding patch; use generated Flutter project."""
from pathlib import Path
import re

root = Path(__file__).resolve().parents[1]
gradle = root / "android/app/build.gradle.kts"
if not gradle.exists():
    raise SystemExit("Run flutter create first")
s = gradle.read_text()
dep = 'implementation("com.wireguard.android:tunnel:1.0.20260102")'
if dep not in s:
    if re.search(r"dependencies\s*\{", s):
        s = re.sub(r"dependencies\s*\{", lambda m: m.group(0) + "\n    " + dep, s, count=1)
    else:
        s += "\ndependencies {\n    " + dep + "\n}\n"
    gradle.write_text(s)
# Stable application ID and Kotlin namespace must match the bundled Activity.
# Keep the app ID independent of the generated project name.
s = gradle.read_text()
s = re.sub(r'namespace\s*=\s*"[^"]+"', 'namespace = "shop.pushok.flow"', s)
s = re.sub(r'applicationId\s*=\s*"[^"]+"', 'applicationId = "shop.pushok.flow"', s)
if 'namespace = "shop.pushok.flow"' not in s or 'applicationId = "shop.pushok.flow"' not in s:
    raise SystemExit("Cannot establish Android namespace/applicationId")
gradle.write_text(s)
manifest = root / "android/app/src/main/AndroidManifest.xml"
s = manifest.read_text()
# The WireGuard AAR already contributes its VPN service via manifest merging.
# Do NOT redeclare it in the app manifest (particularly not exported=true).
# Remove the legacy insertion from v0.3–v0.7 if a scaffold already contains it.
s = re.sub(
    r'\s*<service\s+android:name="com\.wireguard\.android\.backend\.GoBackend\$VpnService"[\s\S]*?</service>',
    '',
    s,
)
# Flutter debug manifests often grant INTERNET only to debug builds. VPN needs it in release as well.
if 'android.permission.INTERNET' not in s:
    s = s.replace('<application', '<uses-permission android:name="android.permission.INTERNET" />\n    <application', 1)
if '<queries>' not in s:
    s = s.replace('</manifest>', """    <queries>
        <intent><action android:name="android.intent.action.MAIN" />
            <category android:name="android.intent.category.LAUNCHER" /></intent>
    </queries>
</manifest>""")
# Keep encrypted preferences off Android Auto Backup: Keystore keys cannot be restored.
if 'android:allowBackup=' not in s:
    s = s.replace('<application', '<application android:allowBackup="false"', 1)
manifest.write_text(s)