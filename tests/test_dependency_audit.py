import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
import dependency_audit as mod

class DependencyAuditTests(unittest.TestCase):
    def test_maven_metadata(self):
        result = mod.parse_wireguard(b'<metadata><versioning><release>1.0.20260102</release></versioning></metadata>')
        self.assertEqual(result, '1.0.20260102')
    def test_flutter_tag(self):
        self.assertEqual(mod.parse_flutter(b'{"current_release":{"stable":"abc"},"releases":[{"hash":"abc","version":"3.50.0"}]}'), '3.50.0')
    def test_upstream_update_report(self):
        def fake(url):
            if 'maven' in url:
                return b'<metadata><versioning><release>1.0.20270101</release></versioning></metadata>'
            return b'{"current_release":{"stable":"def"},"releases":[{"hash":"def","version":"3.51.0"}]}'
        report, outdated, failed = mod.audit(fetch=fake)
        self.assertTrue(outdated)
        self.assertFalse(failed)
        self.assertIn('1.0.20270101', report)
    def test_network_error_reported(self):
        def broken(_): raise OSError('unreachable')
        report, outdated, failed = mod.audit(fetch=broken)
        self.assertFalse(outdated)
        self.assertTrue(failed)
        self.assertIn('Не удалось проверить', report)
    def test_renovate_never_automerge_vpn(self):
        data=json.loads((ROOT/'.github/renovate.json').read_text())
        rule = next(rule for rule in data['packageRules'] if 'com.wireguard.android:tunnel' in rule.get('matchPackageNames', []))
        self.assertIs(rule['automerge'], False)

if __name__ == '__main__': unittest.main()