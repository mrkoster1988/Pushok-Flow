"""The security check must reject insecure merged VPN service manifests."""
from pathlib import Path
import importlib.util
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('verify_android_apk', ROOT / 'tools/verify_android_apk.py')
VERIFY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFY)

SVC = 'com.wireguard.android.backend.GoBackend$VpnService'


def manifest(*, exported='0x0', permission=True):
    return f"""E: manifest (line=2)\n  E: application (line=9)\n    E: service (line=12)\n      A: android:name(0x01010003)=\"{SVC}\"\n      A: android:exported(0x01010010)=(type 0x12){exported}\n""" + ('      A: android:permission(0x01010006)=\"android.permission.BIND_VPN_SERVICE\"\n' if permission else '')


class ManifestSafety(unittest.TestCase):
    def _check(self, service_xml):
        with tempfile.TemporaryDirectory() as td:
            apk = Path(td) / 'app.apk'
            apk.write_bytes(b'fixture')
            commands = iter([
                "package: name='shop.pushok.flow' versionCode='20'",
                'uses-permission: name=\"android.permission.INTERNET\"',
                service_xml,
            ])
            with patch.object(VERIFY.subprocess, 'run', side_effect=lambda *a, **kw: subprocess.CompletedProcess(a[0], 0, stdout=next(commands), stderr='')):
                VERIFY.check_apk(apk, aapt='fake-aapt')

    def test_private_service_with_permission_passes(self):
        self._check(manifest())

    def test_exported_vpn_service_rejected(self):
        with self.assertRaisesRegex(ValueError, 'exported=false'):
            self._check(manifest(exported='0xffffffff'))

    def test_permission_on_unrelated_service_does_not_count(self):
        # Previous validator accepted a permission string anywhere in the APK manifest.
        xml = manifest(permission=False) + '    E: service\n      A: android:permission=\"android.permission.BIND_VPN_SERVICE\"\n'
        with self.assertRaisesRegex(ValueError, 'own declaration'):
            self._check(xml)

    def test_duplicate_vpn_service_rejected(self):
        with self.assertRaisesRegex(ValueError, 'exactly one'):
            self._check(manifest() + manifest())