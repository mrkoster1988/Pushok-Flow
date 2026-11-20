from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
class TestV03Source(unittest.TestCase):
    def test_bridge_methods(self):
        kt = (ROOT / 'native/android/app/src/main/kotlin/shop/pushok/flow/MainActivity.kt').read_text()
        for method in ('connectWireGuard', 'disconnectWireGuard', 'vpnStatus', 'VpnService.prepare', 'Tunnel.State.UP'):
            self.assertIn(method, kt)
    def test_routes_embedded(self):
        routing = (ROOT / 'native/android/app/src/main/kotlin/shop/pushok/flow/WireGuardRouting.kt').read_text()
        self.assertIn('ExcludedApplications', routing)
        self.assertIn('IncludedApplications', routing)
    def test_not_fake_server(self):
        ui = (ROOT / 'lib/main.dart').read_text()
        self.assertIn('WireGuardTunnel.connect', ui)
        self.assertNotIn('WireGuard ещё не интегрирован', ui)