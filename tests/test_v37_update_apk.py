"""Built-manifest safety for self-updates, preserving historical APK verification."""
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

PERMISSIONS = VERIFY.UPDATE_PERMISSIONS | {
    'android.permission.INTERNET', 'android.permission.CAMERA',
    'android.permission.CHANGE_NETWORK_STATE',
    'android.permission.FOREGROUND_SERVICE', 'android.permission.FOREGROUND_SERVICE_SPECIAL_USE',
}


def attribute(name, value, indent=6):
    return f'{" " * indent}A: android:{name}(0x01010003)={value}\n'


def component(tag, name, *, exported='0x0', extra='', children=''):
    result = f'    E: {tag} (line=20)\n' + attribute('name', f'"{name}" (Raw: "{name}")')
    if exported is not None:
        result += attribute('exported', f'(type 0x12){exported}')
    return result + extra + children


REPLACED_FILTER = '''      E: intent-filter (line=30)
        E: action (line=31)
          A: android:name(0x01010003)="android.intent.action.MY_PACKAGE_REPLACED"
'''
CALLBACK = component('receiver', VERIFY.UPDATE_INSTALL_RECEIVER)
REPLACED = component('receiver', VERIFY.UPDATE_REPLACED_RECEIVER, children=REPLACED_FILTER)
PROVIDER = component('provider', VERIFY.UPDATE_PROVIDER, extra=
                     attribute('grantUriPermissions', '(type 0x12)0xffffffff') +
                     attribute('authorities', '"shop.pushok.flow.updates"'))
JOB = component('service', VERIFY.WORK_JOB_SERVICE, exported='0xffffffff', extra=
                attribute('permission', '"android.permission.BIND_JOB_SERVICE"') +
                attribute('enabled', '@0x7f040002'))
WORK_METADATA = '''      E: meta-data (line=40)
        A: android:name(0x01010003)="androidx.work.WorkManagerInitializer"
        A: android:value(0x01010024)="androidx.startup"
'''
INITIALIZER = component('provider', VERIFY.WORK_INITIALIZER_PROVIDER, extra=
                        attribute('authorities', '"shop.pushok.flow.androidx-startup"'), children=WORK_METADATA)
LEGACY_COMPONENTS = component('service', 'com.wireguard.android.backend.GoBackend$VpnService', extra=
                              attribute('permission', '"android.permission.BIND_VPN_SERVICE"')) + \
    component('activity', VERIFY.QR_ACTIVITY) + \
    component('service', VERIFY.XRAY_SERVICE, extra=
              attribute('permission', '"android.permission.BIND_VPN_SERVICE"') +
              attribute('process', '":xray"') +
              attribute('foregroundServiceType', '(type 0x11)0x40000000'))


def manifest(*, callback=CALLBACK, replaced=REPLACED, provider=PROVIDER, job=JOB,
             initializer=INITIALIZER, permissions=PERMISSIONS, app_extra='', extra=''):
    declarations = ''.join('  E: uses-permission (line=5)\n' + attribute('name', f'"{name}"', 4)
                           for name in sorted(permissions))
    features = ''.join('  E: uses-feature (line=6)\n' + attribute('name', f'"{name}"', 4) +
                       attribute('required', '(type 0x12)0x0', 4)
                       for name in ('android.hardware.camera', 'android.hardware.camera.autofocus'))
    return 'E: manifest (line=2)\n' + declarations + features + '  E: application (line=10)\n' + \
        app_extra + LEGACY_COMPONENTS + callback + replaced + provider + job + initializer + extra


class AutomaticUpdateApkGate(unittest.TestCase):
    def check(self, tree=None, permissions=PERMISSIONS):
        VERIFY.check_update_manifest(manifest() if tree is None else tree, permissions)

    def rejected(self, tree, message=None, permissions=PERMISSIONS):
        with self.assertRaisesRegex(ValueError, message or '.'):
            self.check(tree, permissions)

    def test_complete_private_update_surface_passes(self):
        self.check()

    def test_androidx_extras_are_not_a_brittle_inventory(self):
        other = component('receiver', 'androidx.work.impl.background.systemalarm.RescheduleReceiver',
                          extra=attribute('enabled', '(type 0x12)0x0'), children=REPLACED_FILTER)
        other_metadata = '''      E: meta-data
        A: android:name="androidx.lifecycle.ProcessLifecycleInitializer"
        A: android:value="androidx.startup"
'''
        self.check(manifest(initializer=INITIALIZER + other_metadata, extra=other))

    def test_relative_names_resolve_to_the_same_components(self):
        for prefix in ('.', ''):
            with self.subTest(prefix=prefix):
                tree = manifest()
                for name in (VERIFY.UPDATE_INSTALL_RECEIVER, VERIFY.UPDATE_REPLACED_RECEIVER, VERIFY.UPDATE_PROVIDER):
                    tree = tree.replace(name, prefix + name.rsplit('.', 1)[1])
                self.check(tree)

    def test_receivers_must_be_explicitly_private_and_unique(self):
        for field, name in (('callback', VERIFY.UPDATE_INSTALL_RECEIVER),
                            ('replaced', VERIFY.UPDATE_REPLACED_RECEIVER)):
            for exported in (None, '0xffffffff', '0x1'):
                with self.subTest(field=field, exported=exported):
                    children = REPLACED_FILTER if field == 'replaced' else ''
                    self.rejected(manifest(**{field: component('receiver', name, exported=exported,
                                                              children=children)}), 'exported=false')
            with self.subTest(field=field, duplicate=True):
                self.rejected(manifest(extra=component('receiver', '.' + name.rsplit('.', 1)[1])),
                              'exactly one')

    def test_missing_receivers_or_name_only_in_metadata_are_rejected(self):
        self.rejected(manifest(callback=''), 'exactly one')
        self.rejected(manifest(replaced=''), 'exactly one')
        impostor = component('receiver', 'example.Other', children=
                             '      E: meta-data\n' + attribute('name', f'"{VERIFY.UPDATE_INSTALL_RECEIVER}"', 8))
        self.rejected(manifest(callback=impostor), 'exactly one')

    def test_nested_or_duplicate_private_flags_do_not_protect_a_receiver(self):
        nested = component('receiver', VERIFY.UPDATE_INSTALL_RECEIVER, exported=None, children=
                           '      E: meta-data\n' + attribute('exported', '(type 0x12)0x0', 8))
        self.rejected(manifest(callback=nested), 'exported=false')
        self.rejected(manifest(callback=CALLBACK + attribute('exported', '(type 0x12)0x0')), 'exported=false')

    def test_install_callback_has_no_implicit_entry_points(self):
        self.rejected(manifest(callback=CALLBACK + REPLACED_FILTER), 'must not have intent filters')

    def test_replaced_filter_is_exact_and_has_no_data_or_categories(self):
        for filters in ('', REPLACED_FILTER * 2,
                        REPLACED_FILTER.replace('MY_PACKAGE_REPLACED', 'PACKAGE_REPLACED'),
                        REPLACED_FILTER + '        E: category\n' + attribute('name', '"android.intent.category.DEFAULT"', 10),
                        REPLACED_FILTER + '        E: data\n' + attribute('scheme', '"package"', 10),
                        REPLACED_FILTER + '        E: action\n' + attribute('name', '"android.intent.action.BOOT_COMPLETED"', 10)):
            with self.subTest(filters=filters):
                self.rejected(manifest(replaced=component('receiver', VERIFY.UPDATE_REPLACED_RECEIVER,
                                                          children=filters)), 'MY_PACKAGE_REPLACED')

    def test_default_process_and_enabled_callbacks_are_required(self):
        for process in ('":xray"', '"foreign.app"', '""', '@0x7f000001'):
            with self.subTest(process=process):
                self.rejected(manifest(callback=CALLBACK + attribute('process', process)), 'app process')
                self.rejected(manifest(app_extra=attribute('process', process, 4)), 'app process')
        self.rejected(manifest(callback=CALLBACK + attribute('enabled', '(type 0x12)0x0')), 'disabled')
        self.check(manifest(callback=CALLBACK + attribute('process', '"shop.pushok.flow"')))

    def test_install_permissions_are_exact_present_and_unbounded(self):
        for missing in VERIFY.UPDATE_PERMISSIONS:
            with self.subTest(missing=missing):
                self.rejected(manifest(), 'permissions missing', PERMISSIONS - {missing})
                self.rejected(manifest(permissions=PERMISSIONS - {missing}), 'declared once')
                fake = PERMISSIONS - {missing} | {missing + '_FAKE'}
                self.rejected(manifest(permissions=fake), 'permissions missing', fake)
                declaration = '  E: uses-permission\n' + attribute('name', f'"{missing}"', 4)
                self.rejected(manifest() + declaration, 'declared once')
                self.rejected(manifest().replace(f'"{missing}"\n', f'"{missing}"\n' +
                                                 attribute('maxSdkVersion', '(type 0x10)0x1e', 4)), 'maxSdkVersion')

    def test_update_provider_is_single_private_and_grants_only_its_own_authority(self):
        for provider in ('', PROVIDER * 2,
                         PROVIDER.replace('(type 0x12)0x0', '(type 0x12)0xffffffff'),
                         PROVIDER.replace('(type 0x12)0xffffffff', '(type 0x12)0x0'),
                         PROVIDER.replace('shop.pushok.flow.updates', 'other.updates'),
                         PROVIDER.replace(attribute('grantUriPermissions', '(type 0x12)0xffffffff'), '')):
            with self.subTest(provider=provider):
                self.rejected(manifest(provider=provider))
        self.rejected(manifest(provider=component('provider', VERIFY.UPDATE_PROVIDER, exported=None,
                                                  children='      E: meta-data\n' +
                                                  attribute('exported', '(type 0x12)0x0', 8))), 'FileProvider')

    def test_workmanager_job_is_present_and_system_protected(self):
        for job in ('', JOB * 2,
                    JOB.replace('android.permission.BIND_JOB_SERVICE', 'android.permission.INTERNET'),
                    JOB.replace('(type 0x12)0xffffffff', '(type 0x12)0x0'),
                    JOB + attribute('process', '":xray"')):
            with self.subTest(job=job):
                self.rejected(manifest(job=job), 'SystemJobService')

    def test_workmanager_default_initializer_is_present_and_private(self):
        for initializer in ('', INITIALIZER * 2,
                            INITIALIZER.replace('(type 0x12)0x0', '(type 0x12)0xffffffff'),
                            INITIALIZER.replace('shop.pushok.flow.androidx-startup', 'other.startup'),
                            INITIALIZER.replace(WORK_METADATA, ''),
                            INITIALIZER.replace('"androidx.startup"', '"other"'),
                            INITIALIZER + WORK_METADATA):
            with self.subTest(initializer=initializer):
                self.rejected(manifest(initializer=initializer), 'initializer|InitializationProvider')

    def run_apk(self, version, tree):
        with tempfile.TemporaryDirectory() as directory:
            apk = Path(directory) / 'app.apk'
            apk.write_bytes(b'mocked native libraries are checked by test_v36_xray_build')
            output = iter([
                f"package: name='shop.pushok.flow' versionCode='{version}' versionName='0.{version}.0'",
                '\n'.join(f"uses-permission: name='{name}'" for name in sorted(PERMISSIONS)),
                tree,
            ])
            with patch.object(VERIFY.subprocess, 'run', side_effect=lambda *args, **kwargs:
                              subprocess.CompletedProcess(args[0], 0, next(output), '')), \
                    patch.object(VERIFY, 'check_xray_libraries'):
                VERIFY.check_apk(apk, aapt='fixture-aapt')

    def test_version_gate_does_not_break_v35_or_v36_artifacts(self):
        historical = manifest(callback='', replaced='', provider='', job='', initializer='',
                              permissions=PERMISSIONS - VERIFY.UPDATE_PERMISSIONS)
        for version in (35, 36):
            with self.subTest(version=version):
                self.run_apk(version, historical)

    def test_v37_and_future_apks_cannot_skip_auto_update_gate(self):
        self.run_apk(37, manifest())
        for version in (37, 38, 64):
            with self.subTest(version=version), self.assertRaisesRegex(ValueError, 'UpdateInstallReceiver'):
                self.run_apk(version, manifest(callback=''))


if __name__ == '__main__':
    unittest.main()
