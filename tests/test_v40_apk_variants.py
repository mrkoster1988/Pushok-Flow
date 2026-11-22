"""Standalone ABI packages retain identity, completeness and the existing release gates."""
from contextlib import ExitStack
import hashlib
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
import verify_android_apk as APK
import verify_release_apk as RELEASE

ABIS = ('arm64-v8a', 'armeabi-v7a', 'x86_64')
LIBRARIES = ('libflutter.so', 'libapp.so', 'libgojni.so', 'libwg-go.so', 'libwg.so', 'libwg-quick.so')
LICENSES = ('libXray-MIT.txt', 'xray-core-MPL-2.0.txt', 'xray-sources.txt')
MANIFEST = '''E: manifest
  E: application
    A: android:extractNativeLibs(0x010104ea)=(type 0x12)0xffffffff
    E: service (line=10)
      A: android:name="com.wireguard.android.backend.GoBackend$VpnService"
      A: android:exported(0x01010010)=(type 0x12)0x0
      A: android:permission="android.permission.BIND_VPN_SERVICE"
'''


def elf(alignment=16384):
    header = struct.pack('<16sHHIQQQIHHHHHH', b'\x7fELF\x02\x01\x01' + bytes(9),
                         3, 183, 1, 0, 64, 0, 0, 64, 56, 1, 0, 0, 0)
    return header + struct.pack('<IIQQQQQQ', 1, 5, 0, 0, 0, 120, 120, alignment)


def files_for(abis):
    files = {f'lib/{abi}/{library}': elf() for abi in abis for library in LIBRARIES}
    files.update({f'assets/licenses/{name}': b'license notice' for name in LICENSES})
    return files


class StandaloneAbiApkTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.apk = self.root / 'candidate.apk'

    def write(self, files, compression=zipfile.ZIP_DEFLATED):
        with zipfile.ZipFile(self.apk, 'w', compression=compression) as archive:
            for name, data in files.items():
                archive.writestr(name, data)

    def test_each_standalone_abi_requires_explicit_selection(self):
        for abi in ABIS:
            with self.subTest(abi=abi):
                self.write(files_for((abi,)))
                APK.check_compact_native_packaging(self.apk, MANIFEST, abi)
                APK.check_xray_libraries(self.apk, abi)
                with self.assertRaisesRegex(ValueError, 'Required native library missing'):
                    APK.check_compact_native_packaging(self.apk, MANIFEST)
                with self.assertRaisesRegex(ValueError, 'Xray native library missing'):
                    APK.check_xray_libraries(self.apk)

    def test_all_six_libraries_remain_mandatory_in_every_abi(self):
        for abi in ABIS:
            for library in LIBRARIES:
                with self.subTest(abi=abi, library=library):
                    files = files_for((abi,))
                    del files[f'lib/{abi}/{library}']
                    self.write(files)
                    with self.assertRaisesRegex(ValueError, 'Required native library missing'):
                        APK.check_compact_native_packaging(self.apk, MANIFEST, abi)

    def test_mislabeled_universal_and_extra_architectures_are_rejected(self):
        for expected in (None, *ABIS):
            desired = ABIS if expected is None else (expected,)
            for extra in (set(ABIS) - set(desired)) | {'x86', 'riscv64'}:
                with self.subTest(expected=expected, extra=extra):
                    self.write({**files_for(desired), f'lib/{extra}/libgojni.so': elf()})
                    with self.assertRaisesRegex(ValueError, 'ABI set differs'):
                        APK.check_compact_native_packaging(self.apk, MANIFEST, expected)
        self.write(files_for(ABIS))
        with self.assertRaisesRegex(ValueError, 'ABI set differs'):
            APK.check_compact_native_packaging(self.apk, MANIFEST, 'arm64-v8a')

    def test_native_paths_cannot_hide_an_extra_architecture(self):
        for path in ('lib/arm64-v8a/nested/libextra.so', 'lib/libextra.so'):
            with self.subTest(path=path):
                self.write({**files_for(('arm64-v8a',)), path: elf()})
                with self.assertRaisesRegex(ValueError, 'Unexpected native library path'):
                    APK.check_compact_native_packaging(self.apk, MANIFEST, 'arm64-v8a')

    def test_single_abi_cannot_skip_compression_or_extraction(self):
        for abi in ABIS:
            with self.subTest(abi=abi):
                self.write(files_for((abi,)), zipfile.ZIP_STORED)
                with self.assertRaisesRegex(ValueError, 'ZIP DEFLATE'):
                    APK.check_compact_native_packaging(self.apk, MANIFEST, abi)
                self.write(files_for((abi,)))
                with self.assertRaisesRegex(ValueError, 'extractNativeLibs=true'):
                    APK.check_compact_native_packaging(self.apk,
                        MANIFEST.replace('=(type 0x12)0xffffffff', '=(type 0x12)0x0'), abi)

    def test_single_abi_requires_unchanged_elf_and_license_gates(self):
        for abi in ABIS:
            original = files_for((abi,))
            for name in (f'lib/{abi}/libgojni.so', *(f'assets/licenses/{n}' for n in LICENSES)):
                for damage in ('missing', 'empty'):
                    with self.subTest(abi=abi, name=name, damage=damage):
                        files = dict(original)
                        if damage == 'missing':
                            del files[name]
                        else:
                            files[name] = b''
                        self.write(files)
                        with self.assertRaises(ValueError):
                            APK.check_xray_libraries(self.apk, abi)
            self.write({**original, f'lib/{abi}/libgojni.so': elf(4096)})
            with self.assertRaisesRegex(ValueError, '16 KiB'):
                APK.check_xray_libraries(self.apk, abi)

    def test_unknown_expected_abi_is_rejected_before_opening_a_file(self):
        for abi in ('universal', 'x86', '', '../arm64-v8a', 1, True, ['arm64-v8a']):
            with self.subTest(abi=abi), self.assertRaisesRegex(ValueError, 'Unsupported expected native ABI'):
                APK.check_apk(self.apk, 'fixture-aapt', abi)

    def run_gate(self, *, abi='arm64-v8a', version=40, tree=MANIFEST, extra_badging=''):
        outputs = iter([
            f"package: name='shop.pushok.flow' versionCode='{version}' versionName='0.40.0'{extra_badging}",
            "uses-permission: name='android.permission.INTERNET'",
            tree,
        ])
        with ExitStack() as stack:
            stack.enter_context(patch.object(APK.subprocess, 'run', side_effect=lambda *a, **k:
                subprocess.CompletedProcess(a[0], 0, next(outputs), '')))
            gates = {name: stack.enter_context(patch.object(APK, name)) for name in
                ('check_qr_import_manifest', 'check_xray_manifest', 'check_update_manifest')}
            xray = stack.enter_context(patch.object(APK, 'check_xray_libraries', wraps=APK.check_xray_libraries))
            compact = stack.enter_context(patch.object(APK, 'check_compact_native_packaging',
                                                      wraps=APK.check_compact_native_packaging))
            APK.check_apk(self.apk, 'fixture-aapt', abi)
            return gates, xray, compact

    def test_full_dispatch_preserves_old_gates_for_each_explicit_abi(self):
        for abi in ABIS:
            with self.subTest(abi=abi):
                self.write(files_for((abi,)))
                gates, xray, compact = self.run_gate(abi=abi)
                for gate in gates.values():
                    gate.assert_called_once()
                xray.assert_called_once_with(self.apk, abi)
                compact.assert_called_once_with(self.apk, MANIFEST, abi)

    def test_single_abi_cannot_be_debug_historical_or_an_install_time_split(self):
        self.write(files_for(('arm64-v8a',)))
        for values in ({'version': 39}, {'extra_badging': '\napplication-debuggable'},
                       {'extra_badging': " split='config.arm64_v8a'"},
                       {'tree': MANIFEST + '  E: uses-split\n    A: android:name="base"\n'}):
            with self.subTest(values=values), self.assertRaises(ValueError):
                self.run_gate(**values)

    def test_release_version_gate_rejects_flutter_abi_offsets(self):
        for code in (1040, 2040, 4040):
            with self.subTest(code=code), self.assertRaisesRegex(ValueError, 'package/version differs'):
                RELEASE.parse_badging(
                    f"package: name='shop.pushok.flow' versionCode='{code}' versionName='0.40.0'\nsdkVersion:'24'\n",
                    '0.40.0', 40)

    def test_release_report_exposes_abi_only_when_explicitly_verified(self):
        pubspec = self.root / 'pubspec.yaml'
        pubspec.write_text('version: 0.40.0+40\n')
        certificate = 'ab' * 32
        badging = "package: name='shop.pushok.flow' versionCode='40' versionName='0.40.0'\nsdkVersion:'24'\n"
        signature = ('Verified using v2 scheme (APK Signature Scheme v2): true\nNumber of signers: 1\n'
                     f'Signer #1 certificate SHA-256 digest: {certificate}\n')
        for abi in (None, *ABIS):
            with self.subTest(abi=abi):
                self.write(files_for(ABIS if abi is None else (abi,)))
                with patch.object(RELEASE, 'find_aapt', return_value='fixture-aapt'), \
                     patch.object(RELEASE, 'find_apksigner', return_value='fixture-apksigner'), \
                     patch.object(RELEASE, 'check_apk') as checked, \
                     patch.object(RELEASE.subprocess, 'run', side_effect=[
                         subprocess.CompletedProcess([], 0, badging, ''),
                         subprocess.CompletedProcess([], 0, signature, '')]):
                    report = RELEASE.verify(self.apk, pubspec, certificate, abi)
                expected = {'packageName': 'shop.pushok.flow', 'versionName': '0.40.0', 'versionCode': 40,
                            'minSdk': 24, 'certificateSha256': certificate,
                            'sizeBytes': self.apk.stat().st_size,
                            'sha256': hashlib.sha256(self.apk.read_bytes()).hexdigest()}
                if abi is None:
                    checked.assert_called_once_with(self.apk, 'fixture-aapt')
                else:
                    checked.assert_called_once_with(self.apk, 'fixture-aapt', expected_abi=abi)
                    expected['abi'] = abi
                self.assertEqual(report, expected)


if __name__ == '__main__':
    unittest.main()
