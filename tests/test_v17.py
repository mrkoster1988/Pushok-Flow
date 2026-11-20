from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[1]
class V17Tests(unittest.TestCase):
    def test_version(self):
        self.assertIn('v0.17.0', (ROOT / 'docs/RELEASE-v0.17.0.md').read_text())
    def test_peer_rules_rejected(self):
        source = (ROOT / 'native/android/app/src/main/kotlin/shop/pushok/flow/WireGuardRouting.kt').read_text()
        self.assertIn('section == "[interface]"', source)
    def test_kotlin_test_covers_peer(self):
        source = (ROOT / 'native/android/tests/WireGuardRoutingCheck.kt').read_text()
        self.assertIn('ExcludedApplications in Peer accepted', source)