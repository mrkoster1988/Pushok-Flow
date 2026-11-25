from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]

class PrivacyRegressionTests(unittest.TestCase):
    def test_profile_hidden_by_default(self):
        src = (ROOT / 'lib/ui/wireguard_profile_editor.dart').read_text()
        self.assertIn('bool _showConfig = false;', src)
        self.assertIn('obscureText: !_showConfig', src)
        self.assertIn('enableInteractiveSelection: _showConfig', src)
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
        version = re.search(r'(?m)^version: (\d+)\.(\d+)\.(\d+)\+(\d+)$', (ROOT / 'pubspec.yaml').read_text())
        self.assertIsNotNone(version)
        self.assertGreaterEqual(tuple(map(int, version.groups()[:3])), (0, 11, 0))
        self.assertGreaterEqual(int(version[4]), 11)

if __name__ == '__main__':
    unittest.main()
