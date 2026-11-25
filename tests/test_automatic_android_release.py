"""Regression guard: automatic Android release stays signed and fully verified."""
from pathlib import Path
import unittest

WORKFLOW = Path(__file__).resolve().parents[1] / ".github/workflows/android-release.yml"


class AutomaticReleaseTests(unittest.TestCase):
    def test_version_bump_triggers_only_on_main(self):
        text = WORKFLOW.read_text()
        self.assertIn("branches: [main]", text)
        self.assertIn("- 'pubspec.yaml'", text)
        self.assertNotIn("- 'release-requests/flow-v0.64.0-build'", text)
        self.assertIn("git rev-parse HEAD", text)
        self.assertIn("appVersionName", text)
        self.assertIn("appVersionCode", text)

    def test_all_publication_gates_preserved(self):
        text = WORKFLOW.read_text()
        self.assertIn("python3 -m unittest discover -s tests", text)
        self.assertIn("flutter analyze lib test", text)
        self.assertIn("flutter test --reporter expanded", text)
        self.assertIn("check_kotlin_routing.sh", text)
        self.assertIn("configure_android_signing.py", text)
        self.assertIn("verify_release_apk.py", text)
        self.assertIn("Verify update channel continuity", text)
        self.assertIn("create_update_manifest.py", text)
        self.assertIn("gh release create", text)
        self.assertIn("--draft=false --latest", text)
        self.assertIn("secrets.PUSHOK_ANDROID_KEYSTORE_BASE64", text)
        self.assertIn("secrets.PUSHOK_ANDROID_KEY_ALIAS", text)
        self.assertNotIn("temporary key is acceptable", text)


if __name__ == '__main__':
    unittest.main()
