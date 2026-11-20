import unittest
from datetime import datetime, timezone
from pathlib import Path
from zoneinfo import ZoneInfo
from tools.should_run_scheduled_audit import is_scheduled_hour

ROOT = Path(__file__).resolve().parents[1]

class ReleaseV12Tests(unittest.TestCase):
    def test_helsinki_winter_schedule(self):
        self.assertTrue(is_scheduled_hour(datetime(2026, 11, 20, 19, tzinfo=timezone.utc)))
        self.assertFalse(is_scheduled_hour(datetime(2026, 11, 20, 18, tzinfo=timezone.utc)))

    def test_helsinki_summer_schedule(self):
        self.assertTrue(is_scheduled_hour(datetime(2026, 7, 20, 18, tzinfo=timezone.utc)))
        self.assertFalse(is_scheduled_hour(datetime(2026, 7, 20, 19, tzinfo=timezone.utc)))

    def test_rejects_naive_utc_datetime(self):
        with self.assertRaises(ValueError):
            is_scheduled_hour(datetime(2026, 11, 20, 19))

    def test_activity_does_not_leak_permission_callback(self):
        source = (ROOT / 'native/android/app/src/main/kotlin/shop/pushok/flow/MainActivity.kt').read_text()
        self.assertIn('val request = pending', source)
        self.assertIn('pending = null', source)
        self.assertIn('VPN_REQUEST_INTERRUPTED', source)
        self.assertIn('pending != null || Session.operationInProgress.get()', source)

    def test_audit_has_two_utc_crons_and_guard(self):
        workflow = (ROOT / '.github/workflows/dependency-audit.yml').read_text()
        self.assertIn("cron: '0 18 * * *'", workflow)
        self.assertIn("cron: '0 19 * * *'", workflow)
        self.assertIn('should_run_scheduled_audit.py', workflow)
        self.assertIn("if: steps.local_time.outputs.run_audit == 'true'", workflow)

    def test_release_version(self):
        self.assertRegex((ROOT / 'pubspec.yaml').read_text(), r'version: 0\.(?:1[2-9]|[2-9][0-9])\.[0-9]+\+[0-9]+')

if __name__ == '__main__':
    unittest.main()