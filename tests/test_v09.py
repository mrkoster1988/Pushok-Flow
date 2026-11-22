"""Tests for v0.9 Android packaging safety, including apk verification with mocked aapt."""
import importlib.util
from pathlib import Path
from unittest import TestCase, mock
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('verify_android_apk', ROOT / 'tools/verify_android_apk.py')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

class V09Tests(TestCase):
    def test_tunnel_name_is_interface_safe(self):
        src = (ROOT / 'native/android/app/src/main/kotlin/shop/pushok/flow/MainActivity.kt').read_text()
        self.assertIn('getName() = "pushok_flow"', src)
    def test_internet_patched_into_main_manifest(self):
        src = (ROOT / 'tools/patch_android_project.py').read_text()
        self.assertIn('android.permission.INTERNET', src)
    def test_ci_validates_built_apk(self):
        src = (ROOT / '.github/workflows/android-debug-apk.yml').read_text()
        self.assertIn('verify_android_apk.py', src)
    def test_valid_apk_badging(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d)/'test.apk'; p.write_bytes(b'PK')
            good = ["package: name='shop.pushok.flow' versionCode='9'", "uses-permission: name='android.permission.INTERNET'", 'E: service (line=24)\n  A: android:name(0x01010003)="com.wireguard.android.backend.GoBackend$VpnService"\n  A: android:exported(0x01010010)=(type 0x12)0x0\n  A: android:permission="android.permission.BIND_VPN_SERVICE"']
            with mock.patch.object(mod, 'find_aapt', return_value='aapt'), mock.patch.object(mod.subprocess, 'run', side_effect=[subprocess.CompletedProcess([],0,x,'') for x in good]):
                mod.check_apk(p)
    def test_rejects_wrong_package(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d)/'test.apk'; p.write_bytes(b'PK')
            with mock.patch.object(mod, 'find_aapt', return_value='aapt'), mock.patch.object(mod.subprocess, 'run', return_value=subprocess.CompletedProcess([],0,"package: name='wrong.app'",'')):
                with self.assertRaisesRegex(ValueError,'package'):
                    mod.check_apk(p)
    def test_missing_apk(self):
        with self.assertRaisesRegex(ValueError,'Missing'):
            mod.check_apk(Path('/tmp/nonexistent-pushok-flow.apk'))
