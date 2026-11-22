"""Runtime separation, pinned artifacts and native page support are release gates."""
import importlib.util
import io
from pathlib import Path
import struct
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
import fetch_xray_android as FETCH
import verify_android_apk as VERIFY


def elf64(alignment=16384, offset=0, address=0):
    header = struct.pack('<16sHHIQQQIHHHHHH', b'\x7fELF\x02\x01\x01'+bytes(9),
                         3, 183, 1, 0, 64, 0, 0, 64, 56, 1, 0, 0, 0)
    segment = struct.pack('<IIQQQQQQ', 1, 5, offset, address, address, 120, 120, alignment)
    return header + segment


def xray_service(*, exported='0x0', process=':xray', permission='android.permission.BIND_VPN_SERVICE',
                 foreground='0x40000000'):
    return f'''E: manifest
  E: application
    E: service
      A: android:name="shop.pushok.flow.XrayVpnService"
      A: android:exported(0x01010010)=(type 0x12){exported}
      A: android:permission="{permission}"
      A: android:process="{process}"
      A: android:foregroundServiceType(0x01010599)=(type 0x11){foreground}
'''


class XrayApkGates(unittest.TestCase):
    permissions = {'android.permission.FOREGROUND_SERVICE', 'android.permission.FOREGROUND_SERVICE_SPECIAL_USE',
                   'android.permission.ACCESS_NETWORK_STATE'}

    def test_private_separate_runtime_required(self):
        VERIFY.check_xray_manifest(xray_service(), self.permissions)
        for values in ({'exported':'0xffffffff'}, {'process':'shop.pushok.flow'}, {'process':':wireguard'},
                       {'permission':''}, {'foreground':'0x1'}):
            with self.subTest(values=values), self.assertRaises(ValueError):
                VERIFY.check_xray_manifest(xray_service(**values), self.permissions)
        with self.assertRaises(ValueError):
            VERIFY.check_xray_manifest(xray_service()+xray_service(), self.permissions)

    def test_foreground_and_network_permissions_required(self):
        for missing in self.permissions:
            with self.subTest(missing=missing), self.assertRaises(ValueError):
                VERIFY.check_xray_manifest(xray_service(), self.permissions-{missing})

    def test_elf_alignment_and_congruence(self):
        FETCH.verify_elf_16k(elf64())
        for data in (elf64(4096), elf64(0), elf64(24576), elf64(offset=1), b'not an ELF', elf64()[:60]):
            with self.subTest(size=len(data)), self.assertRaises((ValueError, struct.error, IndexError)):
                FETCH.verify_elf_16k(data)

    def test_built_apk_requires_all_supported_abis_and_licenses(self):
        files = {f'lib/{abi}/libgojni.so': elf64() for abi in ('arm64-v8a','armeabi-v7a','x86_64')}
        files.update({f'assets/licenses/{name}': b'license text' for name in
                      ('libXray-MIT.txt','xray-core-MPL-2.0.txt','xray-sources.txt')})
        def check(items):
            with tempfile.TemporaryDirectory() as directory:
                path = Path(directory)/'app.apk'
                with zipfile.ZipFile(path, 'w') as archive:
                    for name, content in items.items(): archive.writestr(name, content)
                VERIFY.check_xray_libraries(path)
        check(files)
        for missing in files:
            with self.subTest(missing=missing), self.assertRaises(ValueError):
                check({name:value for name,value in files.items() if name != missing})

    def test_tampered_cached_artifact_fails_instead_of_being_used(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/'libXray.aar'
            path.write_bytes(b'untrusted AAR')
            with self.assertRaisesRegex(ValueError, 'checksum or size'):
                FETCH.materialize(path)
            self.assertEqual(path.read_bytes(), b'untrusted AAR')

    def test_unverified_archive_never_materializes_an_aar(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory)/'upstream.zip'
            archive.write_bytes(b'corrupt ZIP')
            destination = Path(directory)/'libs/core.aar'
            with self.assertRaisesRegex(ValueError, 'checksum or size'):
                FETCH.materialize(destination, archive)
            self.assertFalse(destination.exists())


if __name__ == '__main__':
    unittest.main()
