"""The merged release must actually permit WorkManager foreground APK transfers."""
import unittest
from tests.test_v37_update_apk import VERIFY, PERMISSIONS, attribute, component, manifest


PERMISSIONS = PERMISSIONS | VERIFY.DOWNLOAD_PERMISSIONS
FOREGROUND = component('service', VERIFY.WORK_FOREGROUND_SERVICE,
                       extra=attribute('foregroundServiceType', '(type 0x11)0x1'))


class ForegroundDownloadApkGate(unittest.TestCase):
    def check(self, service=FOREGROUND, permissions=PERMISSIONS):
        VERIFY.check_update_download_manifest(manifest(extra=service, permissions=permissions), permissions)

    def test_private_data_sync_service_passes(self):
        self.check()
        self.check(FOREGROUND.replace('(type 0x11)0x1', '"dataSync"'))

    def test_missing_exported_wrong_type_or_process_fails(self):
        for service in ('', FOREGROUND * 2,
                        FOREGROUND.replace('(type 0x12)0x0', '(type 0x12)0xffffffff'),
                        FOREGROUND.replace('(type 0x11)0x1', '(type 0x11)0x40000000'),
                        FOREGROUND + attribute('process', '":xray"'),
                        FOREGROUND + attribute('enabled', '(type 0x12)0x0')):
            with self.subTest(service=service), self.assertRaisesRegex(ValueError, 'SystemForegroundService'):
                self.check(service)

    def test_data_sync_and_notification_permissions_are_not_optional_at_build_time(self):
        for missing in VERIFY.DOWNLOAD_PERMISSIONS:
            with self.subTest(missing=missing), self.assertRaisesRegex(ValueError, 'permissions missing'):
                self.check(permissions=PERMISSIONS - {missing})

    def test_permission_max_sdk_cannot_silently_break_new_devices(self):
        tree = manifest(extra=FOREGROUND, permissions=PERMISSIONS)
        for permission in VERIFY.DOWNLOAD_PERMISSIONS:
            broken = tree.replace(f'"{permission}"\n', f'"{permission}"\n' +
                                  attribute('maxSdkVersion', '(type 0x10)0x20', 4))
            with self.subTest(permission=permission), self.assertRaisesRegex(ValueError, 'maxSdkVersion'):
                VERIFY.check_update_download_manifest(broken, PERMISSIONS)


if __name__ == '__main__':
    unittest.main()
