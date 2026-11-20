from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[1]

class RoutingSafetyTests(unittest.TestCase):
    def test_duplicate_interface_rejected(self):
        code = (ROOT / 'native/android/app/src/main/kotlin/shop/pushok/flow/WireGuardRouting.kt').read_text()
        self.assertIn('lines.count', code)
        self.assertIn('== 1', code)

    def test_exact_application_key_matching(self):
        code = (ROOT / 'native/android/app/src/main/kotlin/shop/pushok/flow/WireGuardRouting.kt').read_text()
        self.assertIn('substringBefore', code)
        self.assertNotIn('startsWith("ExcludedApplications"', code)

    def test_version(self):
        self.assertIn('v0.16.0', (ROOT/'docs/RELEASE-v0.16.0.md').read_text())