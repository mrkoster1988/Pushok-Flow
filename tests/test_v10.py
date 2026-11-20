"""Regression contracts for tunnel lifecycle and mutually exclusive operations."""
from pathlib import Path
from unittest import TestCase

ROOT = Path(__file__).resolve().parents[1]
ACTIVITY = ROOT / 'native/android/app/src/main/kotlin/shop/pushok/flow/MainActivity.kt'


class SessionSafetyTests(TestCase):
    def test_tunnel_identity_is_process_scoped(self):
        src = ACTIVITY.read_text()
        self.assertIn('private object Session', src)
        self.assertIn('val tunnel = object : Tunnel', src)
        self.assertIn('private val tunnel get() = Session.tunnel', src)

    def test_backend_survives_activity_recreation(self):
        src = ACTIVITY.read_text()
        self.assertIn('get() = Session.backend', src)
        self.assertIn('set(value) { Session.backend = value }', src)
        self.assertIn('get() = Session.connected', src)

    def test_mutually_exclusive_connect_disconnect(self):
        src = ACTIVITY.read_text()
        self.assertGreaterEqual(src.count('Session.operationInProgress.compareAndSet(false, true)'), 2)
        self.assertGreaterEqual(src.count('Session.operationInProgress.set(false)'), 2)

    def test_route_changes_blocked_during_transition(self):
        src = ACTIVITY.read_text()
        self.assertIn('connected || Session.operationInProgress.get() || pending != null', src)

    def test_error_does_not_leak_profile_to_ui(self):
        src = ACTIVITY.read_text()
        self.assertNotIn('result.error("WG_CONNECT_FAILED", error.message', src)
        self.assertIn('"WG_CONNECT_FAILED", "Не удалось установить туннель.', src)