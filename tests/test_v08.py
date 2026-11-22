"""Executable regression tests for the Android manifest hardening."""
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
ANDROID = 'http://schemas.android.com/apk/res/android'

spec = importlib.util.spec_from_file_location('manifest_check', ROOT / 'tools/check_android_manifest.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def manifest(service='', backup='false'):
    return (f'<manifest xmlns:android="{ANDROID}" xmlns:tools="http://schemas.android.com/tools">'
            '<uses-permission android:name="android.permission.CAMERA" />'
            '<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />'
            '<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />'
            '<uses-permission android:name="android.permission.FOREGROUND_SERVICE_SPECIAL_USE" />'
            '<uses-feature android:name="android.hardware.camera" android:required="false" />'
            '<uses-feature android:name="android.hardware.camera.autofocus" android:required="false" />'
            f'<application android:allowBackup="{backup}">'
            '<activity android:name="shop.pushok.flow.WireGuardQrActivity" android:exported="false" />'
            '<activity android:name="com.journeyapps.barcodescanner.CaptureActivity" tools:node="remove" />'
            '<service android:name="shop.pushok.flow.XrayVpnService" android:exported="false" '
            'android:permission="android.permission.BIND_VPN_SERVICE" android:process=":xray" '
            'android:foregroundServiceType="specialUse">'
            '<intent-filter><action android:name="android.net.VpnService" /></intent-filter>'
            '<property android:name="android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE" '
            'android:value="User initiated encrypted VLESS tunnel with per-app routing" />'
            '<meta-data android:name="android.net.VpnService.SUPPORTS_ALWAYS_ON" android:value="false" />'
            '</service>'
            f'{service}</application></manifest>')


class V08Tests(unittest.TestCase):
    def test_library_wireguard_and_private_xray_declarations_are_valid(self):
        with tempfile.TemporaryDirectory() as d:
            f = Path(d) / 'AndroidManifest.xml'
            f.write_text(manifest())
            module.validate(f)

    def test_legacy_exported_service_is_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            f = Path(d) / 'AndroidManifest.xml'
            f.write_text(manifest('<service android:name="com.wireguard.android.backend.GoBackend$VpnService" android:exported="true" />'))
            with self.assertRaisesRegex(ValueError, 'redeclar'):
                module.validate(f)

    def test_no_backup_is_required(self):
        with tempfile.TemporaryDirectory() as d:
            f = Path(d) / 'AndroidManifest.xml'
            f.write_text(manifest(backup='true'))
            with self.assertRaisesRegex(ValueError, 'backup'):
                module.validate(f)

    def test_manifest_patch_removes_conflicting_service(self):
        src = (ROOT / 'tools/patch_android_project.py').read_text()
        self.assertIn('manifest merging', src)
        self.assertIn('re.sub(', src)
        self.assertNotIn('android:exported="true"', src)

    def test_version_in_ui(self):
        self.assertRegex((ROOT / 'pubspec.yaml').read_text(), r'version: 0\.(?:[89]|[1-9][0-9])\.0\+(?:[89]|[1-9][0-9])')
        version = (ROOT / 'pubspec.yaml').read_text().split('version: ', 1)[1].splitlines()[0].split('+')[0]
        self.assertIn(f"version: '{version}'", (ROOT / 'lib/main.dart').read_text())
        information = (ROOT / 'lib/ui/app_information_sheet.dart').read_text()
        self.assertIn("Text('Версия $version'", information)
        self.assertIn('applicationVersion: version', information)

    def test_android_ci_checks_manifest_before_compile(self):
        ci = (ROOT / '.github/workflows/android-debug-apk.yml').read_text()
        self.assertLess(ci.index('python tools/check_android_manifest.py'), ci.index('compileDebugKotlin'))


if __name__ == '__main__':
    unittest.main()
