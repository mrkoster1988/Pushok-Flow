from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[1]
class ApprovedVisualContract(unittest.TestCase):
    def test_theme_has_neon(self):
        theme = (ROOT/'lib/design/pushok_theme.dart').read_text()
        for token in ('PushokNeonBackdrop', 'PushokNeonButton', '_FlowWavePainter', 'glowCyan', 'glowViolet'):
            self.assertIn(token, theme)
    def test_home_preserves_working_connection(self):
        source = (ROOT/'lib/main.dart').read_text()
        for token in ("Key('pushok_connect_button')", '_toggleTunnel', 'WireGuardTunnel.connect', 'PushokNeonBackdrop', '_homeShortcut'):
            self.assertIn(token, source)
    def test_design_contract(self):
        doc=(ROOT/'docs/DESIGN-SYSTEM.md').read_text()
        self.assertIn('42860.png',doc)
        self.assertIn('Pushok ИИ',doc)
    def test_version(self):
        self.assertRegex((ROOT/'pubspec.yaml').read_text(), r'version: 0\.(?:19|2[0-9])\.0\+(?:19|2[0-9])')