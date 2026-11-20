from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]

class KotlinToolchainTests(unittest.TestCase):
    def test_kotlin_compiler_installed_before_routing_tests(self):
        workflow = (ROOT / '.github/workflows/android-debug-apk.yml').read_text()
        install = workflow.index('name: Install pinned Kotlin CLI')
        verify = workflow.index('name: Validate Kotlin routing logic')
        self.assertLess(install, verify)
        self.assertIn('KOTLIN_VERSION=2.2.21', workflow)
        self.assertIn('echo "$RUNNER_TEMP/pushok-kotlin/kotlinc/bin" >> "$GITHUB_PATH"', workflow)
    def test_flutter_tests_and_apk_verification_exist(self):
        workflow = (ROOT / '.github/workflows/android-debug-apk.yml').read_text()
        self.assertIn('flutter test --reporter expanded', workflow)
        self.assertIn('tools/verify_android_apk.py', workflow)
        self.assertIn('if: always()', workflow)

if __name__ == '__main__':
    unittest.main()