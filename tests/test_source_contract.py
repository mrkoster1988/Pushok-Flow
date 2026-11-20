from pathlib import Path
import json
import unittest

ROOT = Path(__file__).resolve().parents[1]

class ContractTests(unittest.TestCase):
    def test_routing_schema(self):
        data = json.loads((ROOT / 'config/routing_rules.schema.json').read_text())
        self.assertEqual(data['properties']['schema_version']['const'], 1)
        self.assertIn('recommended_bypass_packages', data['required'])

    def test_native_bypass_hook(self):
        body = (ROOT / 'native/android/app/src/main/kotlin/shop/pushok/flow/VpnBypassConfigurator.kt').read_text()
        self.assertIn('builder.addDisallowedApplication(pkg)', body)
        self.assertIn('NameNotFoundException', body)
        self.assertNotIn('builder.establish()', body.replace('builder.establish() inside', ''))

    def test_channel_pair(self):
        dart = (ROOT / 'lib/platform/android_app_routes.dart').read_text()
        kotlin = (ROOT / 'native/android/app/src/main/kotlin/shop/pushok/flow/MainActivity.kt').read_text()
        for op in ('installedApps', 'getBypass', 'setBypass'):
            self.assertIn(op, dart)
            self.assertIn(op, kotlin)
        self.assertIn('shop.pushok.flow/app_routes', dart)
        self.assertIn('shop.pushok.flow/app_routes', kotlin)

if __name__ == '__main__': unittest.main()