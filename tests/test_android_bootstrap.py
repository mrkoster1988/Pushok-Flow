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
MANIFEST_SPEC = importlib.util.spec_from_file_location("android_manifest_check", ROOT / "tools/check_android_manifest.py")
MANIFEST_CHECK = importlib.util.module_from_spec(MANIFEST_SPEC)
MANIFEST_SPEC.loader.exec_module(MANIFEST_CHECK)
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

    def test_subscription_link_routing_is_narrow_and_idempotent(self):
        self.write_manifest()
        manifest = self.patch()
        main = manifest.find('application/activity')
        self.assertEqual(main.get(ANDROID + 'launchMode'), 'singleTop')
        self.assertEqual(main.get(ANDROID + 'exported'), 'true')
        route = [item for item in main.findall('meta-data')
                 if item.get(ANDROID + 'name') == 'flutter_deeplinking_enabled']
        self.assertEqual(len(route), 1)
        self.assertEqual(route[0].get(ANDROID + 'value'), 'false')
        filters = [item for item in main.findall('intent-filter') if item.find('data') is not None]
        self.assertEqual(len(filters), 1)
        self.assertEqual(filters[0].find('data').attrib, {
            ANDROID + 'scheme': 'pushokflow', ANDROID + 'host': 'subscription'})
        MANIFEST_CHECK.validate(self.manifest)
        original = self.manifest.read_bytes()
        self.patch()
        self.assertEqual(self.manifest.read_bytes(), original)

    def test_source_gate_rejects_broad_subscription_links_and_flutter_routes(self):
        for mode in ('missing', 'host', 'extra-data', 'flutter-routing', 'launch-mode'):
            with self.subTest(mode=mode):
                self.write_manifest()
                manifest = self.patch()
                main = manifest.find('application/activity')
                link_filter = next(item for item in main.findall('intent-filter') if item.find('data') is not None)
                if mode == 'missing':
                    main.remove(link_filter)
                elif mode == 'host':
                    link_filter.find('data').set(ANDROID + 'host', '*')
                elif mode == 'extra-data':
                    ET.SubElement(link_filter, 'data', {ANDROID + 'scheme': 'https'})
                elif mode == 'flutter-routing':
                    next(item for item in main.findall('meta-data') if item.get(ANDROID + 'name') ==
                         'flutter_deeplinking_enabled').set(ANDROID + 'value', 'true')
                else:
                    main.set(ANDROID + 'launchMode', 'standard')
                ET.ElementTree(manifest).write(self.manifest)
                with self.assertRaisesRegex(ValueError, 'Subscription'):
                    MANIFEST_CHECK.validate(self.manifest)

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
                         ["android.permission.ACCESS_NETWORK_STATE", "android.permission.CAMERA",
                          "android.permission.CHANGE_NETWORK_STATE",
                          "android.permission.FOREGROUND_SERVICE", "android.permission.FOREGROUND_SERVICE_DATA_SYNC",
                          "android.permission.FOREGROUND_SERVICE_SPECIAL_USE",
                          "android.permission.INTERNET", "android.permission.POST_NOTIFICATIONS",
                          "android.permission.REQUEST_INSTALL_PACKAGES",
                          "android.permission.UPDATE_PACKAGES_WITHOUT_USER_ACTION"])

    def test_update_foreground_service_is_private_data_sync_and_idempotent(self):
        self.write_manifest(services=f'''<service android:name="{PATCH.UPDATE_FOREGROUND_SERVICE}"
            android:exported="true" android:process=":other" android:foregroundServiceType="location" />
            <service android:name="{PATCH.UPDATE_FOREGROUND_SERVICE}" />''')
        self.patch()
        manifest = self.patch()
        services = [item for item in manifest.findall('application/service')
                    if item.get(ANDROID + 'name') == PATCH.UPDATE_FOREGROUND_SERVICE]
        self.assertEqual(len(services), 1)
        self.assertEqual(services[0].get(ANDROID + 'exported'), 'false')
        self.assertEqual(services[0].get(ANDROID + 'foregroundServiceType'), 'dataSync')
        self.assertIsNone(services[0].get(ANDROID + 'process'))
        MANIFEST_CHECK.validate(self.manifest)
        services[0].set(ANDROID + 'foregroundServiceType', 'specialUse')
        ET.ElementTree(manifest).write(self.manifest)
        with self.assertRaisesRegex(ValueError, 'foreground download'):
            MANIFEST_CHECK.validate(self.manifest)

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

    def test_native_compression_preserves_other_packaging_and_removes_stale_manifest_flag(self):
        self.write_manifest(backup='android:extractNativeLibs="false"')
        unrelated = '''android {
    packaging {
        resources { excludes += "META-INF/example-notice.txt" }
        jniLibs { excludes += "**/libunrelated.so" }
    }
}
'''
        self.gradle.write_text(self.gradle.read_text() + unrelated)
        app = self.patch().find('application')
        gradle = self.gradle.read_text()
        self.assertIn(unrelated, gradle)
        self.assertIn('implementation("example:existing:1.0")', gradle)
        self.assertEqual(gradle.count('useLegacyPackaging = true'), 1)
        self.assertEqual(gradle.count('isUniversalApk = true'), 1)
        self.assertEqual(gradle.count('excludes += "lib/x86/**"'), 1)
        # Splitting remains a CLI decision, so the existing debug/release workflows
        # keep their standalone universal output without new flags.
        self.assertNotIn('isEnable = true', gradle)
        self.assertNotIn('abiFilters.add', gradle)
        self.assertNotIn('abiFilters +=', gradle)
        self.assertNotIn(ANDROID + 'extractNativeLibs', app.attrib)
        first = (gradle, self.manifest.read_text())
        self.patch()
        self.assertEqual((self.gradle.read_text(), self.manifest.read_text()), first)

    def test_repeated_bootstrap_repairs_the_owned_native_packaging_setting(self):
        self.write_manifest()
        self.patch()
        self.gradle.write_text(self.gradle.read_text().replace(
            'useLegacyPackaging = true', 'useLegacyPackaging = false').replace(
            'isUniversalApk = true', 'isUniversalApk = false').replace(
            'excludes += "lib/x86/**"', ''))
        self.patch()
        self.assertEqual(self.gradle.read_text().count('useLegacyPackaging = true'), 1)
        self.assertNotIn('useLegacyPackaging = false', self.gradle.read_text())
        self.assertEqual(self.gradle.read_text().count('isUniversalApk = true'), 1)
        self.assertNotIn('isUniversalApk = false', self.gradle.read_text())
        self.assertEqual(self.gradle.read_text().count('excludes += "lib/x86/**"'), 1)

    def test_malformed_native_packaging_markers_fail_before_writing_project(self):
        self.write_manifest()
        original = self.gradle.read_text()
        manifest = self.manifest.read_text()
        for block in (PATCH.NATIVE_PACKAGING_START, PATCH.NATIVE_PACKAGING_END,
                      PATCH.NATIVE_PACKAGING + '\n' + PATCH.NATIVE_PACKAGING,
                      PATCH.NATIVE_PACKAGING_END + '\n' + PATCH.NATIVE_PACKAGING_START):
            with self.subTest(block=block):
                self.gradle.write_text(original + '\n' + block + '\n')
                before = self.gradle.read_text()
                with self.assertRaisesRegex(ValueError, 'native packaging block'):
                    self.patch()
                self.assertEqual(self.gradle.read_text(), before)
                self.assertEqual(self.manifest.read_text(), manifest)

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
                                 [".OtherService", PATCH.UPDATE_FOREGROUND_SERVICE, PATCH.XRAY_SERVICE])

    def test_update_receivers_are_private_deduplicated_and_keep_unrelated_receiver(self):
        self.write_manifest(services='''<receiver android:name=".UpdateInstallReceiver"
            android:exported="true" android:process=":old"><intent-filter /></receiver>
            <receiver android:name="shop.pushok.flow.UpdateInstallReceiver" />
            <receiver android:name=".UpdateReplacedReceiver" android:exported="true">
                <intent-filter><action android:name="android.intent.action.BOOT_COMPLETED" /></intent-filter>
            </receiver><receiver android:name="example.OtherReceiver" android:exported="false" />''')
        app = self.patch().find('application')
        receivers = {item.get(ANDROID + 'name'): item for item in app.findall('receiver')}
        self.assertEqual(len(receivers), 4)
        widget = receivers["shop.pushok.flow.FlowWidget"]
        self.assertEqual(widget.get(ANDROID + "exported"), "false")
        self.assertEqual(widget.find("meta-data").get(ANDROID + "resource"), "@xml/flow_widget")
        self.assertIn('example.OtherReceiver', receivers)
        install = receivers[PATCH.UPDATE_INSTALL_RECEIVER]
        replaced = receivers[PATCH.UPDATE_REPLACED_RECEIVER]
        for receiver in (install, replaced):
            self.assertEqual(receiver.get(ANDROID + 'exported'), 'false')
            self.assertIsNone(receiver.get(ANDROID + 'process'))
        self.assertEqual(install.findall('intent-filter'), [])
        self.assertEqual([item.get(ANDROID + 'name') for item in replaced.findall('intent-filter/action')],
                         ['android.intent.action.MY_PACKAGE_REPLACED'])
        MANIFEST_CHECK.validate(self.manifest)

    def test_source_gate_rejects_unsafe_update_receivers(self):
        for name in (PATCH.UPDATE_INSTALL_RECEIVER, PATCH.UPDATE_REPLACED_RECEIVER):
            for mode in ('missing', 'duplicate', 'exported', 'process', 'filter'):
                with self.subTest(name=name, mode=mode):
                    self.write_manifest()
                    manifest = self.patch()
                    app = manifest.find('application')
                    receiver = next(item for item in app.findall('receiver')
                                    if item.get(ANDROID + 'name') == name)
                    if mode == 'missing':
                        app.remove(receiver)
                    elif mode == 'duplicate':
                        ET.SubElement(app, 'receiver', {ANDROID + 'name': '.' + name.rsplit('.', 1)[1],
                                                       ANDROID + 'exported': 'false'})
                    elif mode == 'filter':
                        extra = ET.SubElement(receiver, 'intent-filter')
                        ET.SubElement(extra, 'action', {ANDROID + 'name': 'example.unsafe'})
                    else:
                        receiver.set(ANDROID + mode, 'true' if mode == 'exported' else ':other')
                    ET.ElementTree(manifest).write(self.manifest)
                    with self.assertRaisesRegex(ValueError, 'Update'):
                        MANIFEST_CHECK.validate(self.manifest)

    def test_source_gate_requires_update_install_permissions(self):
        for name in ('android.permission.REQUEST_INSTALL_PACKAGES',
                     'android.permission.UPDATE_PACKAGES_WITHOUT_USER_ACTION'):
            with self.subTest(name=name):
                self.write_manifest()
                manifest = self.patch()
                manifest.remove(next(item for item in manifest.findall('uses-permission')
                                     if item.get(ANDROID + 'name') == name))
                ET.ElementTree(manifest).write(self.manifest)
                with self.assertRaisesRegex(ValueError, 'Background update'):
                    MANIFEST_CHECK.validate(self.manifest)

    def test_source_gate_requires_physical_network_binding_permission(self):
        self.write_manifest()
        manifest = self.patch()
        manifest.remove(next(item for item in manifest.findall('uses-permission')
                             if item.get(ANDROID + 'name') == 'android.permission.CHANGE_NETWORK_STATE'))
        ET.ElementTree(manifest).write(self.manifest)
        with self.assertRaisesRegex(ValueError, 'Xray foreground service or network permission'):
            MANIFEST_CHECK.validate(self.manifest)

    def test_source_gate_rejects_exposed_or_wrong_update_provider(self):
        for attribute, value in (('exported', 'true'), ('grantUriPermissions', 'false'),
                                 ('authorities', 'example.updates')):
            with self.subTest(attribute=attribute):
                self.write_manifest()
                manifest = self.patch()
                provider = next(item for item in manifest.findall('application/provider')
                                if item.get(ANDROID + 'name') == PATCH.UPDATE_PROVIDER)
                provider.set(ANDROID + attribute, value)
                ET.ElementTree(manifest).write(self.manifest)
                with self.assertRaisesRegex(ValueError, 'Update FileProvider'):
                    MANIFEST_CHECK.validate(self.manifest)

    def test_repeated_bootstrap_is_byte_for_byte_idempotent(self):
        self.write_manifest(queries=PROCESS_TEXT, backup='android:allowBackup="true"')
        self.patch()
        initial = (self.gradle.read_bytes(), self.manifest.read_bytes())
        self.patch()
        self.assertEqual((self.gradle.read_bytes(), self.manifest.read_bytes()), initial)

    def test_private_scanner_and_optional_camera_are_merged_idempotently(self):
        self.write_manifest(services='''<activity android:name=".WireGuardQrActivity" android:exported="true"
            android:screenOrientation="landscape"><intent-filter /></activity>
            <activity android:name="shop.pushok.flow.WireGuardQrActivity" />
            <activity android:name="example.OtherActivity" android:exported="false" />''',
            permissions='''<uses-feature android:name="android.hardware.camera" android:required="true" />
            <uses-feature android:name="android.hardware.camera" android:required="false" />''')
        manifest = self.patch()
        scanners = [item for item in manifest.findall('application/activity')
                    if item.get(ANDROID + 'name') == PATCH.QR_ACTIVITY]
        self.assertEqual(len(scanners), 1)
        scanner = scanners[0]
        self.assertEqual(scanner.get(ANDROID + 'exported'), 'false')
        self.assertEqual(scanner.get(ANDROID + 'excludeFromRecents'), 'true')
        self.assertEqual(scanner.get(ANDROID + 'launchMode'), 'standard')
        self.assertIsNone(scanner.get(ANDROID + 'screenOrientation'))
        self.assertIsNone(scanner.find('intent-filter'))
        self.assertTrue(any(item.get(ANDROID + 'name') == 'example.OtherActivity'
                            for item in manifest.findall('application/activity')))
        features = manifest.findall('uses-feature')
        self.assertEqual(len(features), 5)
        self.assertTrue(all(item.get(ANDROID + 'required') == 'false' for item in features))
        MANIFEST_CHECK.validate(self.manifest)
        initial = self.manifest.read_bytes()
        self.patch()
        self.assertEqual(self.manifest.read_bytes(), initial)

    def test_default_library_scanner_is_removed_and_dependencies_are_pinned(self):
        self.write_manifest(services='''<activity android:name="com.journeyapps.barcodescanner.CaptureActivity"
            android:exported="true"><intent-filter /></activity>''')
        manifest = self.patch()
        generic = [item for item in manifest.findall('application/activity')
                   if item.get(ANDROID + 'name') == 'com.journeyapps.barcodescanner.CaptureActivity']
        self.assertEqual(len(generic), 1)
        self.assertEqual(generic[0].get('{http://schemas.android.com/tools}node'), 'remove')
        self.assertIsNone(generic[0].get(ANDROID + 'exported'))
        self.assertEqual(list(generic[0]), [])
        self.patch()
        gradle = self.gradle.read_text()
        for dependency in ('com.journeyapps:zxing-android-embedded:4.3.0', 'com.google.zxing:core:3.5.4',
                           'androidx.work:work-runtime:2.11.2'):
            self.assertEqual(gradle.count(f'implementation("{dependency}")'), 1)
        MANIFEST_CHECK.validate(self.manifest)

    def test_source_gate_rejects_missing_or_exposed_scanner(self):
        for mode in ('missing', 'exported', 'intent-filter', 'alias', 'duplicate'):
            with self.subTest(mode=mode):
                self.write_manifest()
                manifest = self.patch()
                app = manifest.find('application')
                scanner = next(item for item in app.findall('activity')
                               if item.get(ANDROID + 'name') == PATCH.QR_ACTIVITY)
                if mode == 'missing':
                    app.remove(scanner)
                elif mode == 'exported':
                    scanner.set(ANDROID + 'exported', 'true')
                elif mode == 'intent-filter':
                    ET.SubElement(scanner, 'intent-filter')
                elif mode == 'alias':
                    ET.SubElement(app, 'activity-alias', {ANDROID + 'targetActivity': '.WireGuardQrActivity'})
                else:
                    ET.SubElement(app, 'activity', {ANDROID + 'name': '.WireGuardQrActivity', ANDROID + 'exported': 'false'})
                ET.ElementTree(manifest).write(self.manifest)
                with self.assertRaisesRegex(ValueError, 'QR scanner'):
                    MANIFEST_CHECK.validate(self.manifest)

    def test_source_gate_rejects_required_camera_and_missing_permission(self):
        for mode in ('camera', 'autofocus', 'extra-feature', 'permission'):
            with self.subTest(mode=mode):
                self.write_manifest()
                manifest = self.patch()
                if mode == 'permission':
                    permission = next(item for item in manifest.findall('uses-permission')
                                      if item.get(ANDROID + 'name') == 'android.permission.CAMERA')
                    manifest.remove(permission)
                elif mode == 'extra-feature':
                    ET.SubElement(manifest, 'uses-feature', {ANDROID + 'name': 'android.hardware.camera.level.full'})
                else:
                    feature = next(item for item in manifest.findall('uses-feature')
                                   if item.get(ANDROID + 'name') == 'android.hardware.camera' +
                                   ('.autofocus' if mode == 'autofocus' else ''))
                    feature.set(ANDROID + 'required', 'true')
                ET.ElementTree(manifest).write(self.manifest)
                with self.assertRaises(ValueError):
                    MANIFEST_CHECK.validate(self.manifest)

    def test_source_gate_rejects_media_permissions_and_generic_scanner(self):
        for permission in sorted(MANIFEST_CHECK.MEDIA_PERMISSIONS):
            with self.subTest(permission=permission):
                self.write_manifest(permissions=f'<uses-permission android:name="{permission}" />')
                self.patch()
                with self.assertRaisesRegex(ValueError, 'broad media'):
                    MANIFEST_CHECK.validate(self.manifest)
        self.write_manifest()
        manifest = self.patch()
        generic = next(item for item in manifest.findall('application/activity')
                       if item.get(ANDROID + 'name') == MANIFEST_CHECK.GENERIC_SCANNER)
        generic.attrib.pop('{http://schemas.android.com/tools}node')
        ET.ElementTree(manifest).write(self.manifest)
        with self.assertRaisesRegex(ValueError, 'generic scanner'):
            MANIFEST_CHECK.validate(self.manifest)


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
            "MainActivity.kt", "FlowWidget.kt", "WireGuardRouting.kt", "ConnectionProfile.kt", "VlessProfile.kt",
            "XrayConfig.kt", "XrayNetworkPolicy.kt", "XrayNetworkMonitor.kt", "XrayDnsWire.kt", "XrayDnsBridge.kt", "XrayTunnelStatus.kt", "XrayLifecycle.kt", "XrayTunnelClient.kt", "XrayVpnService.kt", "SecureWireGuardStore.kt",
            "LocalDecisionMemory.kt", "TunnelHealth.kt", "TunnelConnectionSession.kt", "AppUpdates.kt", "UpdatePolicy.kt",
            "UpdateCoordinator.kt", "UpdateWorker.kt", "UpdateInstallReceiver.kt", "UpdateReplacedReceiver.kt",
            "UpdateAutomationPolicy.kt",
            "FlowAccount.kt", "FlowAccountPolicy.kt", "FlowAccountSessionManager.kt", "FlowAccountStore.kt", "FlowAccountClient.kt", "FlowShopBridgePolicy.kt", "FlowShopBridgeClient.kt", "FlowShopBindingStore.kt",
            "ProfileScreenProtection.kt", "ProfileProtectionPolicy.kt",
            "WireGuardProfileImport.kt", "ProfileImportWork.kt", "ProfileImportReader.kt", "ProfileImportPayload.kt", "ProfileQrDecoder.kt",
            "ProfileQrCameraDecoder.kt", "ProfileQrImageReader.kt", "ProfileQrSession.kt", "WireGuardQrActivity.kt",
            "ProfileCatalogStore.kt", "ProfileOperationGate.kt", "SubscriptionPolicy.kt", "SubscriptionFeed.kt", "ManagedWireGuardFeed.kt",
            "SubscriptionLinks.kt", "BoundedNetworkCall.kt", "SubscriptionDownloader.kt", "ProfileSubscriptions.kt", "RouteSettingsStore.kt", "RouteAppAvailability.kt",
            "RouteRecommendationPolicy.kt", "RouteRecommendationStore.kt", "RecommendationAutomation.kt", "RouteRecommendations.kt",
        )
        native = self.project / "native/android/app/src/main/kotlin/shop/pushok/flow"
        native.mkdir(parents=True)
        for name in self.native_names:
            (native / name).write_text(f"// Pushok native {name}\n", encoding="utf-8")
        native_resources = self.project / "native/android/app/src/main/res/xml"
        native_resources.mkdir(parents=True)
        (native_resources / "update_paths.xml").write_text(
            '<paths><files-path name="updates" path="updates/" /></paths>\n', encoding="utf-8")

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
                         '<paths><files-path name="updates" path="updates/" /></paths>\n')
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
