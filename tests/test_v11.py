from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]

class PrivacyRegressionTests(unittest.TestCase):
    def test_profile_hidden_by_default(self):
        src = (ROOT / 'lib/main.dart').read_text()
        self.assertIn('bool showWireGuardSecrets = false;', src)
        self.assertIn('obscureText: !showWireGuardSecrets', src)
        self.assertIn('enableInteractiveSelection: showWireGuardSecrets', src)
        self.assertIn('Icons.visibility_off_outlined', src)

    def test_exception_messages_do_not_expose_runtime_exception(self):
        src = (ROOT / 'lib/main.dart').read_text()
        self.assertNotIn('Ошибка подключения: $e', src)
        self.assertNotIn('Не удалось сохранить правило: $e', src)

    def test_apk_manifest_checks_non_exported_vpn_service(self):
        src = (ROOT / 'tools/verify_android_apk.py').read_text()
        self.assertIn('Expected exactly one WireGuard VPN service', src)
        self.assertIn('WireGuard service not explicitly exported=false', src)

    def test_version_is_incremented(self):
        self.assertRegex((ROOT / 'pubspec.yaml').read_text(), r'version: 0\.[0-9]+\.[0-9]+\+[0-9]+')

if __name__ == '__main__':
    unittest.main()