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
        self.assertIn('val connection = TunnelConnectionSession(', src)
        self.assertIn('private val io get() = Session.connection.io', src)
        self.assertNotIn('Executors.newSingleThreadExecutor()', src)
        self.assertIn('Session.connection.connect(', src)
        self.assertIn('Session.connection.disconnect(', src)

    def test_mutually_exclusive_connect_disconnect(self):
        src = ACTIVITY.read_text()
        self.assertGreaterEqual(src.count('Session.operationInProgress.acquire()'), 3)
        self.assertGreaterEqual(src.count('releaseOperation(token)'), 3)
        release = src.split('private fun releaseOperation(', 1)[1].split('private fun stopTunnels(', 1)[0]
        self.assertIn('Session.operationInProgress.release(token)', release)
        self.assertIn('appUpdates.endConnection(token)', release)

    def test_route_changes_blocked_during_transition(self):
        src = ACTIVITY.read_text()
        routes = src.split('private fun mutateRoutes(', 1)[1].split('override fun configureFlutterEngine', 1)[0]
        self.assertIn('Session.operationInProgress.acquire()', routes)
        self.assertIn('Session.connection.observe(::readTunnelOccupied)', routes)
        read_state = src.split('private fun readTunnelOccupied()', 1)[1].split('private fun stopTunnels', 1)[0]
        self.assertIn('backend?.getState(tunnel)', read_state)
        self.assertIn('xray.status()', read_state)
        self.assertIn('wireGuardUp || xrayState.ownsTunnel', read_state)
        self.assertIn('Session.connection.observe', routes)
        self.assertIn('if (!state.known) throw RouteSettingsFailure("VPN_STATE_UNAVAILABLE")', routes)
        self.assertIn('if (state.occupied) throw RouteSettingsFailure("VPN_ACTIVE")', routes)
        self.assertLess(routes.index('if (!state.known)'), routes.index('routeStore.replace(request)'))
        self.assertLess(routes.index('if (state.occupied)'), routes.index('routeStore.replace(request)'))
        self.assertIn('releaseOperation(token)', routes)

    def test_error_does_not_leak_profile_to_ui(self):
        src = ACTIVITY.read_text()
        self.assertNotIn('result.error("WG_CONNECT_FAILED", error.message', src)
        self.assertIn('"Не удалось установить туннель. Проверьте параметры сервера."', src)
        self.assertIn('profileErrorCode(error, requestedProtocol.connectError)', src)
