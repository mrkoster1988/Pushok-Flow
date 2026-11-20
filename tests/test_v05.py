import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

class V05ContractTests(unittest.TestCase):
    def test_profile_encrypted_with_android_keystore(self):
        text = (ROOT / "native/android/app/src/main/kotlin/shop/pushok/flow/SecureWireGuardStore.kt").read_text()
        for expected in ("AndroidKeyStore", "AES/GCM/NoPadding", "setRandomizedEncryptionRequired(true)", "Cipher.ENCRYPT_MODE", "Cipher.DECRYPT_MODE"):
            self.assertIn(expected, text)

    def test_bootstrap_contains_native_bridge(self):
        text = (ROOT / "tools/bootstrap_android.sh").read_text()
        self.assertIn("SecureWireGuardStore.kt", text)
        self.assertIn("patch_android_project.py", text)

    def test_ci_has_apk_and_no_release_publication(self):
        text = (ROOT / ".github/workflows/android-debug-apk.yml").read_text()
        self.assertIn("flutter build apk --debug", text)
        self.assertNotIn("gh release create", text)

    def test_method_channel_profile_operations(self):
        k = (ROOT / "native/android/app/src/main/kotlin/shop/pushok/flow/MainActivity.kt").read_text()
        d = (ROOT / "lib/platform/wireguard_tunnel.dart").read_text()
        for method in ("saveWireGuardProfile", "loadWireGuardProfile", "deleteWireGuardProfile", "savedProfileExists"):
            self.assertIn(method, k)
            self.assertIn(method, d)

if __name__ == '__main__': unittest.main()