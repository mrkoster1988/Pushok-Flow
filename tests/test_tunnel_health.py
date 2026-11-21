from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]

class TunnelHealthTests(unittest.TestCase):
    def test_health_does_not_expose_sensitive_metadata(self):
        content = (ROOT / 'native/android/app/src/main/kotlin/shop/pushok/flow/TunnelHealth.kt').read_text()
        for field in ['"connected"', '"state"', '"uptimeSeconds"', '"lastErrorCode"']:
            self.assertIn(field, content)
        for field in ['"statistics"', '"rxBytes"', '"txBytes"',
                      '"latestHandshakeAgeSeconds"', '"handshakeStatus"']:
            self.assertIn(field, content)
        for field in ['"PrivateKey"', '"Endpoint"', '"ipAddress"', '"host"',
                      '"peerKey"', '"publicKey"', '"peerSamples"']:
            self.assertNotIn(field, content)

    def test_health_is_compiled_and_bundled(self):
        self.assertIn('TunnelHealth.kt', (ROOT / 'tools/bootstrap_android.sh').read_text())
        self.assertIn('TunnelHealthCheck.kt', (ROOT / 'tools/check_kotlin_routing.sh').read_text())
        self.assertIn('TunnelHealth.snapshot', (ROOT / 'native/android/app/src/main/kotlin/shop/pushok/flow/MainActivity.kt').read_text())

    def test_status_poll_is_cancelled(self):
        ui = (ROOT / 'lib/main.dart').read_text()
        self.assertIn('_healthPoll?.cancel()', ui)
        self.assertIn('Timer.periodic', ui)
        self.assertIn('WireGuardTunnel.diagnostics()', ui)
        self.assertIn('if (info.isKnown)', ui)

if __name__ == '__main__':
    unittest.main()
