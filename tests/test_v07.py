"""Regression checks for Android launcher, package identity and CI gates."""
import pathlib
import re
import unittest
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[1]

class AndroidPackagingTests(unittest.TestCase):
    def test_bootstrap_drops_generated_wrong_package_activity(self):
        source = (ROOT / 'tools/bootstrap_android.sh').read_text()
        self.assertIn('shop/pushok/pushok_flow/MainActivity.kt', source)
        self.assertIn('rm -f', source)

    def test_app_namespace_is_fixed_to_real_native_activity(self):
        source = (ROOT / 'tools/patch_android_project.py').read_text()
        self.assertIn('namespace = "shop.pushok.flow"', source)
        self.assertIn('applicationId = "shop.pushok.flow"', source)
        native = (ROOT / 'native/android/app/src/main/kotlin/shop/pushok/flow/MainActivity.kt').read_text()
        self.assertIn('package shop.pushok.flow', native)

    def test_routing_save_committed_before_acknowledgement(self):
        native = (ROOT / 'native/android/app/src/main/kotlin/shop/pushok/flow/MainActivity.kt').read_text()
        self.assertIn('putStringSet("flow_bypass_packages", packages).commit()', native)
        self.assertIn('routeStore.replace(request)', native)
        self.assertIn('ROUTES_SAVE_FAILED', native)

    def test_ci_compiles_android_module(self):
        ci = (ROOT / '.github/workflows/android-debug-apk.yml').read_text()
        self.assertIn('compileDebugKotlin', ci)
        self.assertIn('processDebugMainManifest', ci)
        self.assertIn('test -s build/app/outputs/flutter-apk/app-debug.apk', ci)

    def test_version(self):
        self.assertRegex((ROOT / 'pubspec.yaml').read_text(), r'version: 0\.(?:[7-9]|[1-9][0-9])\.0\+(?:[7-9]|[1-9][0-9])')

if __name__ == '__main__':
    unittest.main()
