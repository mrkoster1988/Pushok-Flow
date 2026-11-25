import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

class Version13Tests(unittest.TestCase):
    def test_version(self):
        version = re.search(r'(?m)^version: (\d+)\.(\d+)\.(\d+)\+(\d+)$', (ROOT / 'pubspec.yaml').read_text())
        self.assertIsNotNone(version)
        self.assertGreaterEqual(tuple(map(int, version.groups()[:3])), (0, 13, 0))
        self.assertGreaterEqual(int(version[4]), 13)
    def test_kotlin_executable_suite_present(self):
        cases = (ROOT / 'native/android/tests/WireGuardRoutingCheck.kt').read_text()
        self.assertIn('WireGuardRouting.prepare', cases)
        self.assertIn('ExcludedApplications', cases)
        self.assertIn('Missing interface accepted', cases)
    def test_ci_preserves_failure_diagnostics(self):
        flow = (ROOT / '.github/workflows/android-debug-apk.yml').read_text()
        self.assertIn('if: always()', flow)
        self.assertIn('gradle-compile.log', flow)
        self.assertIn('flutter-build.log', flow)
        self.assertIn('set -o pipefail', flow)
    def test_kotlin_compile_script_uses_temporary_directory(self):
        script = (ROOT / 'tools/check_kotlin_routing.sh').read_text()
        self.assertIn('mktemp -d', script)
        self.assertIn('trap ', script)

if __name__ == '__main__':
    unittest.main()