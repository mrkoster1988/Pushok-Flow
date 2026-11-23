"""Check actual ZIP packaging and merged extraction behavior for compact APKs."""
from contextlib import ExitStack
import importlib.util
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import warnings
import zipfile


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('compact_apk_verifier', ROOT / 'tools/verify_android_apk.py')
VERIFY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFY)

ABIS = ('arm64-v8a', 'armeabi-v7a', 'x86_64')
LIBRARIES = ('libflutter.so', 'libapp.so', 'libgojni.so', 'libwg-go.so', 'libwg.so', 'libwg-quick.so')
FILES = {f'lib/{abi}/{library}': b'\x7fELF' + bytes(128)
         for abi in ABIS for library in LIBRARIES}
EXTRACT = '    A: android:extractNativeLibs(0x010104ea)=(type 0x12)0xffffffff\n'
WIREGUARD = '''    E: service (line=20)
      A: android:name(0x01010003)="com.wireguard.android.backend.GoBackend$VpnService"
      A: android:exported(0x01010010)=(type 0x12)0x0
      A: android:permission="android.permission.BIND_VPN_SERVICE"
'''


def manifest(extraction=EXTRACT):
    return 'E: manifest (line=2)\n  E: application (line=10)\n' + extraction + WIREGUARD


class CompactNativeApkGate(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.apk = Path(temporary.name) / 'app.apk'

    def write_apk(self, files=None, *, compression=zipfile.ZIP_DEFLATED, methods=None,
                  duplicate=None):
        files = FILES if files is None else files
        with warnings.catch_warnings():
            warnings.filterwarnings('ignore', message='Duplicate name:', category=UserWarning)
            with zipfile.ZipFile(self.apk, 'w') as archive:
                for name, content in files.items():
                    archive.writestr(name, content, compress_type=(methods or {}).get(name, compression))
                if duplicate is not None:
                    archive.writestr(duplicate, files[duplicate], compress_type=compression)
        return self.apk

    def check(self, tree=None):
        VERIFY.check_compact_native_packaging(self.apk, manifest() if tree is None else tree)

    def test_complete_deflated_universal_apk_passes_both_android_true_encodings(self):
        self.write_apk()
        self.check()
        self.check(manifest(EXTRACT.replace('0xffffffff', '0x1')))
        with zipfile.ZipFile(self.apk) as archive:
            self.assertEqual(len(archive.infolist()), 18)
            self.assertTrue(all(entry.compress_type == zipfile.ZIP_DEFLATED
                                for entry in archive.infolist()))

    def test_requires_exactly_one_application_element(self):
        self.write_apk()
        for tree in ('E: manifest\n' + WIREGUARD, manifest() + '  E: application\n' + EXTRACT):
            with self.subTest(tree=tree), self.assertRaisesRegex(ValueError, 'exactly one application'):
                self.check(tree)

    def test_extraction_must_be_explicit_unique_and_on_application(self):
        self.write_apk()
        for extraction in ('', EXTRACT.replace('0xffffffff', '0x0'),
                           EXTRACT.replace('(type 0x12)0xffffffff', '"true"'),
                           EXTRACT.replace('(type 0x12)', '(type 0x10)'), EXTRACT * 2):
            with self.subTest(extraction=extraction), self.assertRaisesRegex(ValueError, 'extractNativeLibs=true'):
                self.check(manifest(extraction))
        nested = manifest('') + '      E: meta-data\n' + EXTRACT.replace('    A:', '        A:')
        with self.assertRaisesRegex(ValueError, 'extractNativeLibs=true'):
            self.check(nested)

    def test_every_expected_library_is_required(self):
        for missing in FILES:
            with self.subTest(missing=missing):
                self.write_apk({name: data for name, data in FILES.items() if name != missing})
                with self.assertRaisesRegex(ValueError, 'Required native library missing'):
                    self.check()

    def test_all_three_architectures_are_preserved(self):
        for abi in ABIS:
            with self.subTest(abi=abi):
                self.write_apk({name: data for name, data in FILES.items()
                                if not name.startswith(f'lib/{abi}/')})
                with self.assertRaisesRegex(ValueError, 'Required native library missing'):
                    self.check()

    def test_stored_bzip2_and_lzma_native_entries_are_rejected(self):
        name = 'lib/arm64-v8a/libgojni.so'
        for method in (zipfile.ZIP_STORED, zipfile.ZIP_BZIP2, zipfile.ZIP_LZMA):
            with self.subTest(method=method):
                self.write_apk(methods={name: method})
                with self.assertRaisesRegex(ValueError, 'ZIP DEFLATE'):
                    self.check()

    def test_empty_native_library_is_rejected(self):
        for name in ('lib/arm64-v8a/libgojni.so', 'lib/x86_64/libflutter.so', 'lib/armeabi-v7a/libwg.so'):
            with self.subTest(name=name):
                self.write_apk({**FILES, name: b''})
                with self.assertRaisesRegex(ValueError, 'Empty native library'):
                    self.check()

    def test_zip_duplicates_cannot_shadow_native_or_other_entries(self):
        for name in ('lib/arm64-v8a/libgojni.so', 'assets/fixture.txt'):
            with self.subTest(name=name):
                self.write_apk({**FILES, 'assets/fixture.txt': b'asset'}, duplicate=name)
                with self.assertRaisesRegex(ValueError, 'Duplicate APK ZIP entries'):
                    self.check()

    def test_additional_libraries_also_follow_the_compression_contract(self):
        name = 'lib/arm64-v8a/libnew.so'
        files = {**FILES, name: b'\x7fELF' + bytes(128)}
        self.write_apk(files)
        self.check()
        self.write_apk(files, methods={name: zipfile.ZIP_STORED})
        with self.assertRaisesRegex(ValueError, 'ZIP DEFLATE'):
            self.check()

    def test_encrypted_native_metadata_is_rejected_before_extraction(self):
        self.write_apk()
        data = bytearray(self.apk.read_bytes())
        central = data.index(b'PK\x01\x02')
        flags = struct.unpack_from('<H', data, central + 8)[0]
        struct.pack_into('<H', data, central + 8, flags | 1)
        self.apk.write_bytes(data)
        with self.assertRaisesRegex(ValueError, 'Encrypted native libraries'):
            self.check()

    def run_apk(self, version, tree, *, debuggable=False):
        output = iter([
            f"package: name='shop.pushok.flow' versionCode='{version}' versionName='0.{version}.0'" +
            ('\napplication-debuggable' if debuggable else ''),
            "uses-permission: name='android.permission.INTERNET'",
            tree,
        ])
        with ExitStack() as stack:
            stack.enter_context(patch.object(VERIFY.subprocess, 'run', side_effect=lambda *args, **kwargs:
                                subprocess.CompletedProcess(args[0], 0, next(output), '')))
            previous = {name: stack.enter_context(patch.object(VERIFY, name)) for name in (
                'check_qr_import_manifest', 'check_xray_manifest', 'check_xray_libraries', 'check_update_manifest')}
            compact = stack.enter_context(patch.object(VERIFY, 'check_compact_native_packaging',
                                                       wraps=VERIFY.check_compact_native_packaging))
            download = stack.enter_context(patch.object(VERIFY, 'check_update_download_manifest'))
            binding = stack.enter_context(patch.object(VERIFY, 'check_xray_network_binding_permission'))
            VERIFY.check_apk(self.apk, aapt='fixture-aapt')
            self.assertEqual(download.call_count, 1 if version >= 44 else 0)
            self.assertEqual(binding.call_count, 1 if version >= 47 else 0)
            return previous, compact

    def test_historical_apks_keep_their_existing_packaging_contract(self):
        self.write_apk(compression=zipfile.ZIP_STORED)
        for version in (9, 35, 36, 37, 38):
            with self.subTest(version=version):
                _, compact = self.run_apk(version, manifest(''))
                compact.assert_not_called()

    def test_v39_and_future_apks_require_packaging_without_skipping_previous_gates(self):
        for version in (39, 100):
            with self.subTest(version=version):
                self.write_apk()
                previous, compact = self.run_apk(version, manifest())
                compact.assert_called_once()
                for gate in previous.values():
                    gate.assert_called_once()
                with self.assertRaisesRegex(ValueError, 'extractNativeLibs=true'):
                    self.run_apk(version, manifest(''))
                self.write_apk(compression=zipfile.ZIP_STORED)
                with self.assertRaisesRegex(ValueError, 'ZIP DEFLATE'):
                    self.run_apk(version, manifest())

    def test_v39_jit_debug_without_aot_libraries_keeps_existing_safety_gates(self):
        self.write_apk({name: data for name, data in FILES.items() if not name.endswith('/libapp.so')},
                       compression=zipfile.ZIP_STORED)
        previous, compact = self.run_apk(39, manifest(''), debuggable=True)
        compact.assert_not_called()
        for gate in previous.values():
            gate.assert_called_once()
        with self.assertRaisesRegex(ValueError, 'Required native library missing'):
            self.run_apk(39, manifest(), debuggable=False)


if __name__ == '__main__':
    unittest.main()
