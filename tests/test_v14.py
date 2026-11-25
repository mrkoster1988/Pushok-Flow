from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]

class BuildSafetyTests(unittest.TestCase):
    def setUp(self):
        self.workflow = (ROOT / '.github/workflows/android-debug-apk.yml').read_text()

    def test_analyze_pipeline_fails_closed(self):
        self.assertRegex(self.workflow, r'(?s)name: Static analysis\n\s+run: \|\n\s+set -o pipefail\n\s+flutter analyze lib')

    def test_bootstrap_pipeline_fails_closed(self):
        self.assertRegex(self.workflow, r'(?s)name: Generate Android project.*?set -o pipefail.*?bash tools/bootstrap_android.sh')

    def test_kotlin_executable_checks_run_before_apk(self):
        self.assertIn('bash tools/check_kotlin_routing.sh', self.workflow)
        self.assertLess(self.workflow.index('bash tools/check_kotlin_routing.sh'), self.workflow.index('flutter build apk'))

    def test_apk_validator_runs_after_build(self):
        self.assertLess(self.workflow.index('flutter build apk'), self.workflow.index('python tools/verify_android_apk.py'))

    def test_version(self):
        version = re.search(r'(?m)^version: (\d+)\.(\d+)\.(\d+)\+(\d+)$', (ROOT / 'pubspec.yaml').read_text())
        self.assertIsNotNone(version)
        self.assertGreaterEqual(tuple(map(int, version.groups()[:3])), (0, 14, 0))
        self.assertGreaterEqual(int(version[4]), 14)

if __name__ == '__main__':
    unittest.main()