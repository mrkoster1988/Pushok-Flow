from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]

class FlutterGateTests(unittest.TestCase):
    def test_version(self):
        self.assertRegex((ROOT/'pubspec.yaml').read_text(), r'version: 0\.(?:1[5-9]|[2-9]\d)\.\d+\+\d+')

    def test_widget_test_is_real_flutter_test(self):
        t = (ROOT/'test/app_smoke_test.dart').read_text()
        self.assertIn('testWidgets(', t)
        self.assertIn('pumpWidget(const PushokFlowApp())', t)

    def test_build_requires_widget_tests(self):
        s = (ROOT/'.github/workflows/android-debug-apk.yml').read_text()
        self.assertIn('flutter test --reporter expanded', s)
        self.assertLess(s.index('flutter test --reporter expanded'), s.index('flutter build apk'))
        self.assertIn('set -o pipefail\n          flutter test', s)

    def test_checks_run_flutter_test(self):
        self.assertIn('flutter test', (ROOT/'.github/workflows/source-checks.yml').read_text())

    def test_no_unused_caught_exception_in_ui(self):
        self.assertNotIn('catch (e)', (ROOT/'lib/main.dart').read_text())