"""Verify QR privacy and device compatibility in the built, merged APK."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('verify_android_apk', ROOT / 'tools/verify_android_apk.py')
VERIFY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFY)

VPN = '''    E: service (line=20)
      A: android:name(0x01010003)="com.wireguard.android.backend.GoBackend$VpnService"
      A: android:permission(0x01010006)="android.permission.BIND_VPN_SERVICE"
      A: android:exported(0x01010010)=(type 0x12)0x0
'''


def feature(name, required='0x0'):
    declaration = f'''  E: uses-feature (line=8)
    A: android:name(0x01010003)="{name}" (Raw: "{name}")
'''
    if required is not None:
        declaration += f'    A: android:required(0x0101028e)=(type 0x12){required}\n'
    return declaration


def scanner(name=VERIFY.QR_ACTIVITY, exported='0x0', extra=''):
    declaration = f'''    E: activity (line=30)
      A: android:name(0x01010003)="{name}" (Raw: "{name}")
'''
    if exported is not None:
        declaration += f'      A: android:exported(0x01010010)=(type 0x12){exported}\n'
    return declaration + extra


def manifest(*, features=None, activity=None):
    if features is None:
        features = feature('android.hardware.camera') + feature('android.hardware.camera.autofocus')
    if activity is None:
        activity = scanner()
    return 'E: manifest (line=2)\n' + features + '  E: application (line=15)\n' + VPN + activity


class QrManifestSafety(unittest.TestCase):
    def check_apk(self, xml=None, *, version='35', permissions=('INTERNET', 'CAMERA')):
        if xml is None:
            xml = manifest()
        with tempfile.TemporaryDirectory() as directory:
            apk = Path(directory) / 'app.apk'
            apk.write_bytes(b'fixture')
            version_attribute = '' if version is None else f" versionCode='{version}'"
            outputs = iter([
                "package: name='shop.pushok.flow'" + version_attribute + " versionName='0.35.0'",
                '\n'.join(f"uses-permission: name='android.permission.{name}'" for name in permissions),
                xml,
            ])
            with patch.object(VERIFY.subprocess, 'run', side_effect=lambda *args, **kwargs:
                              subprocess.CompletedProcess(args[0], 0, next(outputs), '')):
                VERIFY.check_apk(apk, aapt='fake-aapt')

    def test_private_scanner_and_optional_camera_pass(self):
        self.check_apk()

    def test_historical_pre_qr_release_remains_verifiable(self):
        self.check_apk(manifest(features='', activity=''), version='34', permissions=('INTERNET',))

    def test_future_release_cannot_skip_qr_checks(self):
        with self.assertRaisesRegex(ValueError, 'CAMERA permission'):
            self.check_apk(version='36', permissions=('INTERNET',))

    def test_missing_or_invalid_version_cannot_bypass_checks(self):
        for version in (None, '', '0', '-1', '035', 'unknown', '35.0'):
            with self.subTest(version=version), self.assertRaisesRegex(ValueError, 'versionCode'):
                self.check_apk(version=version)

    def test_camera_permission_must_be_exact(self):
        with self.assertRaisesRegex(ValueError, 'CAMERA permission'):
            self.check_apk(permissions=('INTERNET', 'CAMERA_FAKE'))

    def test_storage_and_gallery_permissions_rejected(self):
        for permission in sorted(VERIFY.STORAGE_PERMISSIONS):
            with self.subTest(permission=permission), self.assertRaisesRegex(ValueError, 'storage or gallery'):
                self.check_apk(permissions=('INTERNET', 'CAMERA', permission.removeprefix('android.permission.')))

    def test_scanner_activity_required(self):
        with self.assertRaisesRegex(ValueError, 'exactly one app-owned'):
            self.check_apk(manifest(activity=''))

    def test_library_activity_is_not_the_app_scanner(self):
        with self.assertRaisesRegex(ValueError, 'default QR scanner must be removed'):
            self.check_apk(manifest(activity=scanner(name='com.journeyapps.barcodescanner.CaptureActivity')))

    def test_unprotected_library_scanner_cannot_remain_alongside_app_scanner(self):
        with self.assertRaisesRegex(ValueError, 'default QR scanner must be removed'):
            self.check_apk(manifest(activity=scanner() + scanner(name='com.journeyapps.barcodescanner.CaptureActivity')))

    def test_relative_component_names_are_supported(self):
        for name in ('.WireGuardQrActivity', 'WireGuardQrActivity'):
            with self.subTest(name=name):
                self.check_apk(manifest(activity=scanner(name=name)))

    def test_duplicate_scanner_rejected(self):
        with self.assertRaisesRegex(ValueError, 'exactly one app-owned'):
            self.check_apk(manifest(activity=scanner() + scanner(name='.WireGuardQrActivity')))

    def test_scanner_must_be_explicitly_private(self):
        for exported in ('0xffffffff', '0x1', None):
            with self.subTest(exported=exported), self.assertRaisesRegex(ValueError, 'scanner must be explicitly exported=false'):
                self.check_apk(manifest(activity=scanner(exported=exported)))

    def test_nested_private_flag_does_not_protect_scanner(self):
        nested = '      E: meta-data\n        A: android:exported(0x01010010)=(type 0x12)0x0\n'
        with self.assertRaisesRegex(ValueError, 'scanner must be explicitly exported=false'):
            self.check_apk(manifest(activity=scanner(exported=None, extra=nested)))

    def test_scanner_name_in_metadata_does_not_count(self):
        nested = '      E: meta-data\n        A: android:value="' + VERIFY.QR_ACTIVITY + '"\n'
        with self.assertRaisesRegex(ValueError, 'exactly one app-owned'):
            self.check_apk(manifest(activity=scanner(name='shop.pushok.flow.MainActivity', extra=nested)))

    def test_exported_alias_cannot_expose_private_scanner(self):
        alias = '''    E: activity-alias
      A: android:name="shop.pushok.flow.ScannerAlias"
      A: android:targetActivity=".WireGuardQrActivity"
      A: android:exported(0x01010010)=(type 0x12)0xffffffff
'''
        with self.assertRaisesRegex(ValueError, 'scanner alias'):
            self.check_apk(manifest(activity=scanner() + alias))

    def test_camera_and_autofocus_must_override_implicit_requirements(self):
        for missing in ('android.hardware.camera', 'android.hardware.camera.autofocus'):
            features = ''.join(feature(name) for name in ('android.hardware.camera', 'android.hardware.camera.autofocus')
                               if name != missing)
            with self.subTest(missing=missing), self.assertRaisesRegex(ValueError, 'optional camera hardware'):
                self.check_apk(manifest(features=features))

    def test_no_camera_feature_can_be_required(self):
        for name in ('android.hardware.camera', 'android.hardware.camera.any', 'android.hardware.camera.front',
                     'android.hardware.camera.autofocus', 'android.hardware.camera.flash'):
            for required in (None, '0xffffffff'):
                with self.subTest(name=name, required=required), self.assertRaisesRegex(ValueError, 'required=false'):
                    features = feature('android.hardware.camera') + feature('android.hardware.camera.autofocus') + feature(name, required)
                    self.check_apk(manifest(features=features))

    def test_optional_extra_camera_features_pass(self):
        features = ''.join(feature('android.hardware.camera' + suffix)
                           for suffix in ('', '.autofocus', '.any', '.front', '.flash'))
        self.check_apk(manifest(features=features))

    def test_nested_optional_flag_does_not_protect_required_feature(self):
        nested = feature('android.hardware.camera', None) + '    E: meta-data\n      A: android:required(0x0101028e)=(type 0x12)0x0\n'
        with self.assertRaisesRegex(ValueError, 'required=false'):
            self.check_apk(manifest(features=nested + feature('android.hardware.camera.autofocus')))


if __name__ == '__main__':
    unittest.main()
