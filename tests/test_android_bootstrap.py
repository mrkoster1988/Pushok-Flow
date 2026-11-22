"""Exercise the generated Android project patch on real manifest XML."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("android_patch", ROOT / "tools/patch_android_project.py")
PATCH = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PATCH)
ANDROID = "{http://schemas.android.com/apk/res/android}"
VPN_SERVICE = "com.wireguard.android.backend.GoBackend$VpnService"
PROCESS_TEXT = """<queries>
    <intent>
        <action android:name="android.intent.action.PROCESS_TEXT" />
        <data android:mimeType="text/plain" />
    </intent>
</queries>"""
LAUNCHER = """<intent>
    <action android:name="android.intent.action.MAIN" />
    <category android:name="android.intent.category.LAUNCHER" />
</intent>"""


class AndroidBootstrapTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.manifest = self.root / "android/app/src/main/AndroidManifest.xml"
        self.manifest.parent.mkdir(parents=True)
        self.gradle = self.root / "android/app/build.gradle.kts"
        self.gradle.write_text('''android {
    namespace = "shop.pushok.pushok_flow"
    defaultConfig {
        applicationId = "shop.pushok.pushok_flow"
    }
}
dependencies {
    implementation("example:existing:1.0")
}
''', encoding="utf-8")

    def write_manifest(self, *, queries="", services="", backup="", permissions=""):
        self.manifest.write_text(f'''<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    {permissions}
    <!-- Keep Flutter metadata and application placeholders. -->
    <application android:name="${{applicationName}}" {backup}>
        <activity android:name=".MainActivity" android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>
        <meta-data android:name="flutterEmbedding" android:value="2" />
        {services}
    </application>
    {queries}
</manifest>''', encoding="utf-8")

    def patch(self):
        PATCH.patch_project(self.root)
        return ET.parse(self.manifest).getroot()

    def launcher_queries(self, manifest):
        return [intent for intent in manifest.findall("queries/intent")
                if any(action.get(ANDROID + "name") == "android.intent.action.MAIN"
                       for action in intent.findall("action"))
                and any(category.get(ANDROID + "name") == "android.intent.category.LAUNCHER"
                        for category in intent.findall("category"))]

    def test_flutter_process_text_query_survives_launcher_merge(self):
        self.write_manifest(queries=PROCESS_TEXT)
        manifest = self.patch()
        self.assertEqual(len(manifest.findall("queries")), 1)
        self.assertEqual(len(self.launcher_queries(manifest)), 1)
        intents = manifest.findall("queries/intent")
        process_text = next(intent for intent in intents if any(
            action.get(ANDROID + "name") == "android.intent.action.PROCESS_TEXT"
            for action in intent.findall("action")))
        self.assertEqual(process_text.find("data").get(ANDROID + "mimeType"), "text/plain")
        app = manifest.find("application")
        self.assertEqual(app.get(ANDROID + "name"), "${applicationName}")
        self.assertEqual(app.find("meta-data").get(ANDROID + "value"), "2")
        self.assertIn("Keep Flutter metadata", self.manifest.read_text())

    def test_creates_queries_when_missing(self):
        self.write_manifest()
        manifest = self.patch()
        self.assertEqual(len(self.launcher_queries(manifest)), 1)
        self.assertEqual(manifest.find("application").get(ANDROID + "allowBackup"), "false")
        internet = [permission for permission in manifest.findall("uses-permission")
                    if permission.get(ANDROID + "name") == "android.permission.INTERNET"]
        self.assertEqual(len(internet), 1)
        gradle = self.gradle.read_text()
        self.assertIn('namespace = "shop.pushok.flow"', gradle)
        self.assertIn('applicationId = "shop.pushok.flow"', gradle)
        self.assertIn('implementation("example:existing:1.0")', gradle)
        self.assertEqual(gradle.count('implementation("com.wireguard.android:tunnel:1.0.20260102")'), 1)

    def test_existing_launcher_and_permission_are_not_duplicated(self):
        self.write_manifest(queries=f"<queries>{LAUNCHER}</queries>",
                            permissions='<uses-permission android:name="android.permission.INTERNET" />')
        manifest = self.patch()
        self.assertEqual(len(manifest.findall("queries/intent")), 1)
        self.assertEqual(len(self.launcher_queries(manifest)), 1)
        self.assertEqual(sorted(p.get(ANDROID + "name") for p in manifest.findall("uses-permission")),
                         ["android.permission.INTERNET", "android.permission.REQUEST_INSTALL_PACKAGES"])

    def test_update_provider_is_private_and_preserves_other_providers(self):
        self.write_manifest(services='''<provider android:name="shop.pushok.flow.UpdateFileProvider"
            android:exported="true" android:authorities="old.updates" />
            <provider android:name="example.OtherProvider" android:authorities="other" />''')
        app = self.patch().find("application")
        providers = app.findall("provider")
        self.assertEqual(len(providers), 2)
        provider = next(p for p in providers if p.get(ANDROID + "name") == PATCH.UPDATE_PROVIDER)
        self.assertEqual(provider.get(ANDROID + "exported"), "false")
        self.assertEqual(provider.get(ANDROID + "grantUriPermissions"), "true")
        self.assertEqual(provider.get(ANDROID + "authorities"), "${applicationId}.updates")
        self.assertEqual(provider.find("meta-data").get(ANDROID + "resource"), "@xml/update_paths")
        self.assertEqual(app.get(ANDROID + "label"), "Pushok Flow")

    def test_removes_only_legacy_vpn_service_and_disables_existing_backup(self):
        for legacy in (
            f'<service android:exported="true" android:name="{VPN_SERVICE}" />',
            f'<service android:name="{VPN_SERVICE}"><intent-filter /></service>',
        ):
            with self.subTest(legacy=legacy):
                self.write_manifest(services=legacy + '<service android:name=".OtherService" />',
                                    backup='android:allowBackup="true"')
                app = self.patch().find("application")
                self.assertEqual(app.get(ANDROID + "allowBackup"), "false")
                self.assertEqual([service.get(ANDROID + "name") for service in app.findall("service")],
                                 [".OtherService"])

    def test_repeated_bootstrap_is_byte_for_byte_idempotent(self):
        self.write_manifest(queries=PROCESS_TEXT, backup='android:allowBackup="true"')
        self.patch()
        initial = (self.gradle.read_bytes(), self.manifest.read_bytes())
        self.patch()
        self.assertEqual((self.gradle.read_bytes(), self.manifest.read_bytes()), initial)


class BootstrapScriptTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name)
        self.project = self.base / "project with spaces"
        self.temp = self.base / "scaffold temp"
        self.temp.mkdir()
        self.project.mkdir()
        self.preserved = {
            "lib/main.dart": "void main() { /* Pushok application */ }\n",
            "pubspec.yaml": "name: pushok_flow\nversion: 0.21.0+21\n",
            "test/app_smoke_test.dart": "// Existing Pushok widget test.\n",
            "README.md": "Pushok Flow project instructions.\n",
            "android/APP_INTEGRATION.md": "Keep native integration instructions.\n",
            "android/WIREGUARD_DEPENDENCY.gradle.kts": "// Dependency reference.\n",
        }
        for path, content in self.preserved.items():
            target = self.project / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(content, encoding="utf-8")
        (self.project / "tools").mkdir()
        for tool in ("bootstrap_android.sh", "patch_android_project.py"):
            shutil.copy2(ROOT / "tools" / tool, self.project / "tools" / tool)

        self.native_names = (
            "MainActivity.kt", "WireGuardRouting.kt", "SecureWireGuardStore.kt",
            "LocalDecisionMemory.kt", "TunnelHealth.kt", "TunnelConnectionSession.kt", "AppUpdates.kt", "UpdatePolicy.kt",
            "ProfileScreenProtection.kt", "ProfileProtectionPolicy.kt",
            "WireGuardProfileImport.kt", "ProfileImportReader.kt",
            "ProfileCatalogStore.kt", "ProfileOperationGate.kt", "RouteSettingsStore.kt",
        )
        native = self.project / "native/android/app/src/main/kotlin/shop/pushok/flow"
        native.mkdir(parents=True)
        for name in self.native_names:
            (native / name).write_text(f"// Pushok native {name}\n", encoding="utf-8")
        native_resources = self.project / "native/android/app/src/main/res/xml"
        native_resources.mkdir(parents=True)
        (native_resources / "update_paths.xml").write_text(
            '<paths><cache-path name="updates" path="updates/" /></paths>\n', encoding="utf-8")

        # The fake executable emits Android files plus the real create command's
        # unrelated app/test templates. The bootstrap must copy only Android.
        outputs = {
            "android/app/build.gradle.kts": '''android {
    namespace = "shop.pushok.pushok_flow"
    defaultConfig { applicationId = "shop.pushok.pushok_flow" }
}
''',
            "android/app/src/main/AndroidManifest.xml": f'''<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <application android:name="${{applicationName}}">
        <activity android:name=".MainActivity" />
    </application>
    {PROCESS_TEXT}
</manifest>''',
            "android/app/src/main/kotlin/shop/pushok/pushok_flow/MainActivity.kt": "// Generated activity.\n",
            "android/gradlew": "#!/usr/bin/env sh\nexit 0\n",
            "android/gradle/wrapper/gradle-wrapper.properties": "distributionUrl=generated\n",
            "lib/main.dart": "// Counter app MyApp.\n",
            "pubspec.yaml": "name: generated_template\n",
            "test/widget_test.dart": "// Counter test expects MyApp.\n",
            "analysis_options.yaml": "include: package:flutter_lints/flutter.yaml\n",
            "README.md": "Generated template.\n",
            ".metadata": "Generated template metadata.\n",
        }
        self.outputs = self.base / "flutter-outputs.json"
        self.outputs.write_text(json.dumps(outputs), encoding="utf-8")
        self.calls = self.base / "flutter-calls.jsonl"
        bin_dir = self.base / "bin"
        bin_dir.mkdir()
        flutter = bin_dir / "flutter"
        flutter.write_text('''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

target = Path(sys.argv[-1])
with open(os.environ["FLOW_STUB_CALLS"], "a", encoding="utf-8") as log:
    log.write(json.dumps({"args": sys.argv[1:], "target": str(target)}) + "\\n")
outputs = json.loads(Path(os.environ["FLOW_STUB_OUTPUTS"]).read_text())
for name, content in outputs.items():
    path = target / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    if name == "android/gradlew":
        path.chmod(0o755)
sys.exit(int(os.environ.get("FLOW_STUB_EXIT", "0")))
''', encoding="utf-8")
        flutter.chmod(0o755)
        self.environment = {
            **os.environ,
            "PATH": str(bin_dir) + os.pathsep + os.environ.get("PATH", ""),
            "TMPDIR": str(self.temp),
            "FLOW_STUB_OUTPUTS": str(self.outputs),
            "FLOW_STUB_CALLS": str(self.calls),
            "FLOW_STUB_EXIT": "0",
        }

    def bootstrap(self, *, expected_code=0):
        result = subprocess.run(
            ["bash", str(self.project / "tools/bootstrap_android.sh")],
            cwd=self.base, env=self.environment, capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, expected_code, result.stdout + result.stderr)
        return result

    def assert_app_preserved(self):
        for path, content in self.preserved.items():
            self.assertEqual((self.project / path).read_text(), content, path)
        self.assertFalse((self.project / "test/widget_test.dart").exists())
        self.assertFalse((self.project / "analysis_options.yaml").exists())
        self.assertFalse((self.project / ".metadata").exists())

    def test_bootstrap_copies_only_android_and_can_be_repeated(self):
        self.bootstrap()
        self.assert_app_preserved()
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()]
        self.assertEqual(len(calls), 1)
        self.assertNotEqual(Path(calls[0]["target"]), self.project)
        self.assertFalse(Path(calls[0]["target"]).exists())
        self.assertEqual(list(self.temp.iterdir()), [])
        android = self.project / "android"
        self.assertTrue((android / "gradlew").stat().st_mode & 0o100)
        self.assertTrue((android / "gradle/wrapper/gradle-wrapper.properties").exists())
        self.assertFalse((android / "app/src/main/kotlin/shop/pushok/pushok_flow/MainActivity.kt").exists())
        self.assertEqual((android / "app/src/main/res/xml/update_paths.xml").read_text(),
                         '<paths><cache-path name="updates" path="updates/" /></paths>\n')
        for name in self.native_names:
            self.assertEqual((android / "app/src/main/kotlin/shop/pushok/flow" / name).read_text(),
                             f"// Pushok native {name}\n")
        initial = {str(path.relative_to(android)): path.read_bytes()
                   for path in android.rglob("*") if path.is_file()}
        self.bootstrap()
        self.assert_app_preserved()
        self.assertEqual(len(self.calls.read_text().splitlines()), 1)
        self.assertEqual({str(path.relative_to(android)): path.read_bytes()
                          for path in android.rglob("*") if path.is_file()}, initial)

    def test_failed_generation_cleans_temporary_files_and_leaves_app_untouched(self):
        self.environment["FLOW_STUB_EXIT"] = "7"
        self.bootstrap(expected_code=7)
        self.assert_app_preserved()
        self.assertEqual(list(self.temp.iterdir()), [])
        self.assertFalse((self.project / "android/app").exists())


if __name__ == "__main__":
    unittest.main()
