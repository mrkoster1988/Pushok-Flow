"""Fail-closed signing and release metadata checks without real credentials."""
import base64
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
import configure_android_signing as signing
import create_update_manifest as updates
import verify_release_apk as release


class PrivateSigningTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.gradle = self.root / 'android/app/build.gradle.kts'
        self.gradle.parent.mkdir(parents=True)
        self.original = '''plugins { id("com.android.application") }
android {
    namespace = "shop.pushok.flow"
    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}
'''
        self.gradle.write_text(self.original)
        self.environment = {
            'PUSHOK_ANDROID_KEYSTORE_BASE64': base64.b64encode(b'fake-test-keystore' * 12).decode(),
            'PUSHOK_ANDROID_KEYSTORE_PASSWORD': 'TEST_STORE_PASSWORD_NEVER_PERSIST',
            'PUSHOK_ANDROID_KEY_ALIAS': 'TEST_ALIAS_NEVER_PERSIST',
            'PUSHOK_ANDROID_KEY_PASSWORD': 'TEST_KEY_PASSWORD_NEVER_PERSIST',
            'RUNNER_TEMP': str(self.root),
            'GITHUB_ENV': str(self.root / 'github-env'),
        }

    def test_missing_signing_values_leave_project_unchanged(self):
        for name in signing.REQUIRED:
            with self.subTest(secret=name):
                environment = {**self.environment, name: ''}
                with self.assertRaises(ValueError):
                    signing.configure(self.root, environment)
                self.assertEqual(self.gradle.read_text(), self.original)
                self.assertEqual(list(self.root.glob('pushok-signing-*')), [])

    def test_bad_base64_cannot_fall_back_to_debug_key(self):
        with self.assertRaises(ValueError):
            signing.configure(self.root, {**self.environment,
                'PUSHOK_ANDROID_KEYSTORE_BASE64': 'INVALID BASE64 SECRET!@#'})
        self.assertEqual(self.gradle.read_text(), self.original)
        self.assertFalse((self.root / 'github-env').exists())

    def test_failed_keystore_validation_removes_temporary_key_and_hides_error(self):
        failure = subprocess.CompletedProcess([], 1, b'', b'PRIVATE_NATIVE_KEYTOOL_MESSAGE')
        with mock.patch.object(signing.shutil, 'which', return_value='/usr/bin/keytool'), \
             mock.patch.object(signing.subprocess, 'run', return_value=failure):
            with self.assertRaisesRegex(ValueError, 'certificate could not be read') as error:
                signing.configure(self.root, self.environment)
        self.assertNotIn('PRIVATE_NATIVE', str(error.exception))
        self.assertEqual(list(self.root.glob('pushok-signing-*')), [])
        self.assertEqual(self.gradle.read_text(), self.original)

    def test_private_key_and_environment_do_not_embed_secrets_in_gradle(self):
        certificate = b'public-test-certificate-der'
        success = subprocess.CompletedProcess([], 0, certificate, b'')
        with mock.patch.object(signing.shutil, 'which', return_value='/usr/bin/keytool'), \
             mock.patch.object(signing.subprocess, 'run', return_value=success) as called:
            values = signing.configure(self.root, self.environment)
        keystore = Path(values['PUSHOK_ANDROID_KEYSTORE_FILE'])
        self.assertEqual(keystore.stat().st_mode & 0o777, 0o600)
        self.assertEqual(keystore.parent.stat().st_mode & 0o777, 0o700)
        self.assertEqual(values['PUSHOK_ANDROID_CERTIFICATE_SHA256'], hashlib.sha256(certificate).hexdigest())
        written = self.gradle.read_text() + (self.root / 'github-env').read_text()
        for name in signing.REQUIRED:
            self.assertNotIn(self.environment[name], written)
            if name != 'PUSHOK_ANDROID_KEY_ALIAS':
                self.assertNotIn(self.environment[name], ' '.join(called.call_args.args[0]))
        self.assertNotIn('signingConfigs.getByName("debug")', self.gradle.read_text())
        self.assertIn('isDebuggable = false', self.gradle.read_text())
        self.assertEqual(signing.patch_signing(self.gradle.read_text()), self.gradle.read_text())


class ReleaseMetadataTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.pubspec = self.root / 'pubspec.yaml'
        self.pubspec.write_text('name: pushok_flow\nversion: 0.24.0+24\n')
        self.apk = self.root / 'app-release.apk'
        self.apk.write_bytes(b'release-apk-fixture-bytes')
        self.certificate = 'ab' * 32
        self.verified = {
            'packageName': 'shop.pushok.flow', 'versionName': '0.24.0',
            'versionCode': 24, 'minSdk': 24,
            'certificateSha256': self.certificate,
            'sha256': hashlib.sha256(self.apk.read_bytes()).hexdigest(),
            'sizeBytes': self.apk.stat().st_size,
        }

    def test_release_identity_is_checked_against_pubspec(self):
        valid = "package: name='shop.pushok.flow' versionCode='24' versionName='0.24.0' platformBuildVersionName='16'\nsdkVersion:'24'\n"
        self.assertEqual(release.parse_badging(valid, '0.24.0', 24)['minSdk'], 24)
        for bad in (valid.replace("versionCode='24'", "versionCode='23'"),
                    valid.replace('shop.pushok.flow', 'shop.pushok.other'),
                    valid.replace("sdkVersion:'24'", "sdkVersion:'25'"),
                    valid + 'application-debuggable\n'):
            with self.subTest(badging=bad):
                with self.assertRaises(ValueError):
                    release.parse_badging(bad, '0.24.0', 24)

    def test_certificate_must_match_and_have_verified_v2_signature(self):
        valid = 'Verified using v2 scheme (APK Signature Scheme v2): true\n' \
            'Number of signers: 1\n' \
            f'Signer #1 certificate SHA-256 digest: {self.certificate}\n'
        self.assertEqual(release.parse_certificate(valid, self.certificate), self.certificate)
        for bad in (valid.replace('true', 'false'), valid.replace(self.certificate, 'cd' * 32),
                    valid + f'Signer #2 certificate SHA-256 digest: {self.certificate}\n'):
            with self.subTest(signature=bad):
                with self.assertRaises(ValueError):
                    release.parse_certificate(bad, self.certificate)

    def test_actual_sdk37_v2_and_v3_certificate_reports_are_supported(self):
        # Observed with official Build Tools 37.0.0 on an existing debug APK,
        # then on a disposable copy signed with a temporary v2+v3 test key.
        reports = (
            ('V2 Signer:', False,
             'a8f87d13782ffcd8d98c3c6006219d8d754caf5e8b2914b26985caaa41f78198'),
            ('V3.0 Signer:', True,
             '38b80d4a9dd4b86d2abba200703dfb6ca343589c2441108c8161b644803fd3f9'),
        )
        for label, v3, certificate in reports:
            with self.subTest(label=label):
                report = (
                    'Verifies\n'
                    'Verified using v1 scheme (JAR signing): false\n'
                    'Verified using v2 scheme (APK Signature Scheme v2): true\n'
                    f'Verified using v3 scheme (APK Signature Scheme v3): {str(v3).lower()}\n'
                    'Verified using v3.1 scheme (APK Signature Scheme v3.1): false\n'
                    'Verified using v3.2 scheme (APK Signature Scheme v3.2): false\n'
                    'Verified using v4 scheme (APK Signature Scheme v4): false\n'
                    'Verified for SourceStamp: false\n'
                    'Number of signers: 1\n'
                    f'{label} certificate SHA-256 digest: {certificate}\n'
                    f'{label} public key SHA-256 digest: {"cd" * 32}\n'
                )
                self.assertEqual(release.parse_single_signer_certificate(report), certificate)
                self.assertEqual(release.parse_certificate(report, certificate), certificate)
                with self.assertRaises(ValueError):
                    release.parse_certificate(report, self.certificate)

    def test_scheme_reports_must_share_one_certificate(self):
        header = 'Verified using v2 scheme (APK Signature Scheme v2): true\nNumber of signers: 1\n'
        v2 = f'V2 Signer: certificate SHA-256 digest: {self.certificate}\n'
        v3 = f'V3.0 Signer: certificate SHA-256 digest: {self.certificate}\n'
        v31 = f'V3.1 Signer: certificate SHA-256 digest: {self.certificate}\n'
        self.assertEqual(release.parse_certificate(header + v2 + v3 + v31, self.certificate),
                         self.certificate)
        for bad in (header + v2 + v3.replace(self.certificate, 'cd' * 32),
                    header + v2 + v2, header + v2 + v3 + v31.replace(self.certificate, 'cd' * 32)):
            with self.subTest(report=bad):
                with self.assertRaises(ValueError):
                    release.parse_certificate(bad, self.certificate)

    def test_signer_count_unknown_labels_and_rotation_fail_closed(self):
        valid = 'Verified using v2 scheme (APK Signature Scheme v2): true\n' \
            'Number of signers: 1\n' \
            f'V2 Signer: certificate SHA-256 digest: {self.certificate}\n'
        bad_reports = [valid.replace('Number of signers: 1\n', count) for count in (
            '', 'Number of signers: 0\n', 'Number of signers: 2\n',
            'Number of signers: 1\nNumber of signers: 1\n')]
        bad_reports += [valid.replace('V2 Signer:', label) for label in (
            'Signer #2', 'Unknown Signer:', 'Source Stamp Signer:', 'Signer #1 in lineage',
            'V3.0 Signer: (minSdkVersion=28, maxSdkVersion=32)',
            'V3.2 Hybrid Classical Signer:')]
        bad_reports += [valid + f'Unknown Signer: certificate SHA-256 digest: {self.certificate}\n']
        for bad in bad_reports:
            with self.subTest(report=bad):
                with self.assertRaises(ValueError):
                    release.parse_certificate(bad, self.certificate)

    def test_manifest_and_checksum_describe_exact_staged_bytes(self):
        verified = self.root / 'verified.json'
        verified.write_text(json.dumps(self.verified))
        manifest = updates.stage(self.apk, verified, self.pubspec, self.root / 'dist')
        self.assertEqual(manifest['schemaVersion'], 1)
        self.assertEqual(manifest['apkUrl'],
            'https://github.com/mrkoster1988/Pushok-Flow/releases/download/v0.24.0/Pushok-Flow-v0.24.0.apk')
        target = self.root / 'dist/Pushok-Flow-v0.24.0.apk'
        self.assertEqual(target.read_bytes(), self.apk.read_bytes())
        self.assertEqual(json.loads((self.root / 'dist/update.json').read_text()), manifest)
        self.assertEqual((self.root / 'dist/Pushok-Flow-v0.24.0.apk.sha256').read_text(),
            f"{manifest['sha256']}  Pushok-Flow-v0.24.0.apk\n")

    def test_changed_apk_or_verification_report_cannot_create_update(self):
        for changes in ({'versionCode': 23}, {'packageName': 'other.app'},
                        {'sha256': '00' * 32}, {'sizeBytes': 1}, {'certificateSha256': ''}):
            with self.subTest(changes=changes):
                with self.assertRaises(ValueError):
                    updates.build_manifest(self.apk, {**self.verified, **changes}, self.pubspec)
        self.apk.write_bytes(b'changed-after-verification')
        with self.assertRaises(ValueError):
            updates.build_manifest(self.apk, self.verified, self.pubspec)

    def test_update_channel_refuses_key_changes_and_version_rollback(self):
        current = updates.build_manifest(self.apk, self.verified, self.pubspec)
        previous = {**current, 'versionCode': 23, 'versionName': '0.23.0'}
        updates.validate_previous_manifest(current, previous)
        for changes in ({'versionCode': 24}, {'versionCode': 25}, {'versionCode': True},
                        {'certificateSha256': 'cd' * 32}, {'packageName': 'other.app'}):
            with self.subTest(changes=changes):
                with self.assertRaises(ValueError):
                    updates.validate_previous_manifest(current, {**previous, **changes})

    def test_stable_android_version_is_required(self):
        for value in ('0.24.0', '0.24.0+0', '0.24.0+2100000001', '0.24.0-beta+24', '0.024.0+24'):
            with self.subTest(version=value):
                self.pubspec.write_text(f'version: {value}\n')
                with self.assertRaises(ValueError):
                    release.read_version(self.pubspec)


if __name__ == '__main__':
    unittest.main()
