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
            f'Signer #1 certificate SHA-256 digest: {self.certificate}\n'
        self.assertEqual(release.parse_certificate(valid, self.certificate), self.certificate)
        for bad in (valid.replace('true', 'false'), valid.replace(self.certificate, 'cd' * 32),
                    valid + f'Signer #2 certificate SHA-256 digest: {self.certificate}\n'):
            with self.subTest(signature=bad):
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
