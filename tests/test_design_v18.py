from pathlib import Path
import re
import unittest
ROOT = Path(__file__).resolve().parents[1]
class DesignV18Tests(unittest.TestCase):
    def test_single_theme(self):
        main = (ROOT / 'lib/main.dart').read_text()
        self.assertIn('theme: buildPushokTheme()', main)
        self.assertIn('PushokPanel', main)
    def test_mascot_asset(self):
        self.assertTrue((ROOT / 'assets/mascot/pushok.png').is_file())
        self.assertIn('assets/mascot/pushok.png', (ROOT / 'pubspec.yaml').read_text())
    def test_buttons_and_tones(self):
        theme = (ROOT / 'lib/design/pushok_theme.dart').read_text()
        for token in ('0xFF061827','0xFF102D40','0xFF39C8C3','0xFF087C56','0xFFA92F45','NavigationBarThemeData'):
            self.assertIn(token, theme)
    def test_connect_button_semantics(self):
        main = (ROOT / 'lib/main.dart').read_text()
        self.assertIn("Key('pushok_connect_button')", main)
        self.assertIn("'Подключить'", main)
        self.assertIn("'Отключить'", main)
    def test_version(self):
        version = re.search(r'(?m)^version: (\d+)\.(\d+)\.(\d+)\+(\d+)$', (ROOT / 'pubspec.yaml').read_text())
        self.assertIsNotNone(version)
        self.assertGreaterEqual(tuple(map(int, version.groups()[:3])), (0, 18, 0))
        self.assertGreaterEqual(int(version[4]), 18)