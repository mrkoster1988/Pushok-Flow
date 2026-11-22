"""Authenticated data updates must not publish corrupt, replaced or older data."""
import base64
import copy
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock

from tools import route_recommendations as recommendations


def payload(version=1, packages=None):
    return {"schema_version": 1, "rules_version": version,
            "recommended_bypass_packages": ["com.example.one"] if packages is None else packages}


def snapshot(version, encoded):
    return recommendations.VerifiedRecommendations(version, (), encoded, b"s" * 256)


class RecommendationFormatTests(unittest.TestCase):
    def test_canonical_source_has_stable_package_order_and_no_unknown_fields(self):
        first = payload(7, ["org.example.z", "com.example.a"])
        second = {"recommended_bypass_packages": ["com.example.a", "org.example.z"],
                  "rules_version": 7, "schema_version": 1}
        self.assertEqual(recommendations.canonical_payload(first),
                         recommendations.canonical_payload(second))
        parsed = json.loads(recommendations.canonical_payload(first))
        self.assertEqual(parsed["recommended_bypass_packages"], ["com.example.a", "org.example.z"])
        self.assertEqual(first["recommended_bypass_packages"], ["org.example.z", "com.example.a"])

    def test_payload_rejects_schema_types_versions_and_executable_fields(self):
        changes = [
            {"schema_version": True}, {"schema_version": 1.0}, {"schema_version": 2},
            {"rules_version": False}, {"rules_version": 0}, {"rules_version": -1},
            {"rules_version": 2147483648}, {"rules_version": 1.0}, {"rules_version": "1"},
            {"recommended_bypass_packages": None}, {"recommended_bypass_packages": "com.example.app"},
            {"url": "https://example.invalid/commands"}, {"script": "doSomething()"},
        ]
        for change in changes:
            with self.subTest(change=change):
                invalid = payload()
                invalid.update(change)
                with self.assertRaises(ValueError):
                    recommendations.canonical_payload(invalid)
        with self.assertRaises(ValueError):
            recommendations.canonical_payload({"schema_version": 1, "rules_version": 1})

    def test_packages_are_bounded_unique_exact_identifiers(self):
        invalid_lists = [["com.example.app", "com.example.app"], [None], [17], [True],
                         ["MAX"], ["com.example.app\n"], ["com..app"], [".com.app"],
                         ["com.app/other"], ["com.приложение"], ["com.a\x00"],
                         ["com." + "a" * 252], [f"com.example.p{i}" for i in range(257)]]
        for packages in invalid_lists:
            with self.subTest(packages=packages[:2]):
                with self.assertRaises(ValueError):
                    recommendations.canonical_payload(payload(packages=packages))
        valid = recommendations.canonical_payload(payload(packages=[]))
        self.assertEqual(json.loads(valid)["recommended_bypass_packages"], [])
        recommendations.canonical_payload(payload(packages=["com." + "a" * 251]))

    def test_source_rejects_duplicate_fields_invalid_utf8_and_trailing_json(self):
        cases = [b'{"schema_version":1,"schema_version":1,"rules_version":1,"recommended_bypass_packages":[]}',
                 b'{"schema_version":1,"rules_version":NaN,"recommended_bypass_packages":[]}',
                 b'{"schema_version":1,"rules_version":1,"recommended_bypass_packages":[]} {}',
                 b'\xff', b"[" * 1500 + b"]" * 1500]
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "source.json"
            for content in cases:
                with self.subTest(content=content[:40]):
                    source.write_bytes(content)
                    with self.assertRaises(ValueError):
                        recommendations.read_payload(source)

    def test_envelope_rejects_ambiguous_base64_fields_and_limits(self):
        encoded = recommendations.encode_envelope(b"{}", b"s" * 256)
        document = json.loads(encoded)
        cases = []
        for mutation in (
            {"schema_version": True}, {"schema_version": 2}, {"extra": "ignored?"},
            {"payload": "e30=\n"}, {"payload": "e31="},  # Non-zero padding bits.
            {"payload": "é"}, {"payload": ""}, {"payload": False},
            {"signature": base64.b64encode(b"s" * 255).decode()},
            {"signature": base64.b64encode(b"s" * 1025).decode()},
            {"payload": base64.b64encode(b"x" * 65537).decode()},
        ):
            invalid = copy.deepcopy(document)
            invalid.update(mutation)
            cases.append(json.dumps(invalid).encode())
        cases.extend([encoded + b"{}", b" " * 131073,
                      b'{"schema_version":1,"schema_version":1,"payload":"e30=","signature":"x"}'])
        for invalid in cases:
            with self.subTest(encoded=invalid[:60]):
                with self.assertRaises(ValueError):
                    recommendations.decode_envelope(invalid)

    def test_payload_byte_limit_applies_even_with_valid_package_count_and_lengths(self):
        packages = [f"com.p{i:03d}." + "a" * 246 for i in range(256)]
        self.assertTrue(all(len(package) == 255 for package in packages))
        with self.assertRaisesRegex(ValueError, "size limit"):
            recommendations.canonical_payload(payload(packages=packages))

    def test_revision_rejects_rollback_or_same_version_changed_bytes(self):
        previous = snapshot(3, b"original bytes")
        recommendations.require_revision(snapshot(4, b"new bytes"), previous, allow_identical=False)
        recommendations.require_revision(snapshot(3, b"original bytes"), previous, allow_identical=True)
        for candidate, identical in [(snapshot(2, b"older"), True),
                                     (snapshot(3, b"different bytes"), True),
                                     (snapshot(3, b"original bytes"), False)]:
            with self.subTest(version=candidate.rules_version, identical=identical):
                with self.assertRaises(ValueError):
                    recommendations.require_revision(candidate, previous, allow_identical=identical)

    def test_atomic_failure_or_concurrent_output_change_preserves_existing_file(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "catalogue.json"
            output.write_bytes(b"previous valid catalogue")
            with mock.patch.object(recommendations.os, "replace", side_effect=OSError("disk error")):
                with self.assertRaises(OSError):
                    recommendations._atomic_write(output, b"new catalogue", b"previous valid catalogue")
            self.assertEqual(output.read_bytes(), b"previous valid catalogue")
            with self.assertRaisesRegex(ValueError, "changed during"):
                recommendations._atomic_write(output, b"new catalogue", b"another writer's old snapshot")
            self.assertEqual(output.read_bytes(), b"previous valid catalogue")
            self.assertEqual(list(Path(directory).iterdir()), [output])


@unittest.skipUnless(shutil.which("java") and shutil.which("keytool"), "Java 17+ and keytool required")
class RecommendationSignatureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="pushok-test-data-signing-")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.work = Path(cls.temporary.name)
        cls.keystore = cls.work / "ephemeral-test-only.p12"
        cls.certificate = cls.work / "test-certificate.der"
        cls.other_certificate = cls.work / "other-test-certificate.der"
        environment = os.environ.copy()
        environment["FLOW_TEST_PASSWORD"] = "ephemeral-testing-only"
        for alias, certificate in (("test-only", cls.certificate), ("other-test-only", cls.other_certificate)):
            subprocess.run(["keytool", "-genkeypair", "-alias", alias,
                            "-keystore", str(cls.keystore), "-storetype", "PKCS12",
                            "-storepass:env", "FLOW_TEST_PASSWORD", "-keypass:env", "FLOW_TEST_PASSWORD",
                            "-keyalg", "RSA", "-keysize", "2048", "-validity", "2",
                            "-dname", "CN=Ephemeral test only", "-noprompt"],
                           env=environment, capture_output=True, check=True)
            subprocess.run(["keytool", "-exportcert", "-alias", alias,
                            "-keystore", str(cls.keystore), "-storepass:env", "FLOW_TEST_PASSWORD",
                            "-file", str(certificate)], env=environment, capture_output=True, check=True)
        cls.fingerprint = hashlib.sha256(cls.certificate.read_bytes()).hexdigest()
        cls.environment = {
            "FLOW_DATA_KEYSTORE": str(cls.keystore),
            "FLOW_DATA_STORE_PASSWORD": "ephemeral-testing-only",
            "FLOW_DATA_KEY_PASSWORD": "ephemeral-testing-only",
            "FLOW_DATA_KEY_ALIAS": "test-only",
        }
        cls.source = cls.work / "source.json"
        cls.source.write_text(json.dumps(payload(1, ["org.example.second", "com.example.first"])))
        cls.envelope = cls.work / "signed.json"
        with mock.patch.dict(os.environ, cls.environment):
            cls.signed = recommendations.sign(cls.source, cls.envelope, cls.certificate,
                                              expected_certificate_sha256=cls.fingerprint)

    def test_real_rsa_roundtrip_checks_exact_source_and_accepts_identical_revision(self):
        actual = recommendations.verify(self.envelope, self.certificate, payload=self.source,
                                        previous=self.envelope,
                                        expected_certificate_sha256=self.fingerprint)
        self.assertEqual(actual.rules_version, 1)
        self.assertEqual(actual.packages, ("com.example.first", "org.example.second"))
        self.assertEqual(actual.payload, recommendations.read_payload(self.source))
        # Verification does not require any keystore environment variables.
        with mock.patch.dict(os.environ, {name: "" for name in self.environment}):
            recommendations.verify(self.envelope, self.certificate,
                                   expected_certificate_sha256=self.fingerprint)

    def test_tampered_payload_signature_or_certificate_is_rejected(self):
        raw = self.envelope.read_bytes()
        signed_payload, signature = recommendations.decode_envelope(raw)
        changed = signed_payload.replace(b'"rules_version":1', b'"rules_version":2')
        for bad in (recommendations.encode_envelope(changed, signature),
                    recommendations.encode_envelope(signed_payload,
                                                    bytes([signature[0] ^ 1]) + signature[1:])):
            with self.assertRaisesRegex(ValueError, "signature operation"):
                recommendations.verify_bytes(bad, self.certificate,
                                             expected_certificate_sha256=self.fingerprint)
        with self.assertRaisesRegex(ValueError, "signature operation"):
            recommendations.verify_bytes(raw, self.other_certificate,
                                         expected_certificate_sha256=self.fingerprint)
        with self.assertRaisesRegex(ValueError, "signature operation"):
            recommendations.verify_bytes(raw, self.other_certificate,
                expected_certificate_sha256=hashlib.sha256(self.other_certificate.read_bytes()).hexdigest())

    def test_production_cli_rejects_ephemeral_test_signing_identity(self):
        with mock.patch("sys.stderr") as stderr:
            result = recommendations.main(["verify", "--envelope", str(self.envelope),
                                           "--certificate", str(self.certificate)])
        self.assertEqual(result, 1)
        self.assertIn("signature operation failed", "".join(str(call.args[0]) for call in stderr.write.mock_calls))

    def test_changed_source_and_republishing_same_revision_preserve_output(self):
        destination = self.work / "retained.json"
        original = self.envelope.read_bytes()
        destination.write_bytes(original)
        with mock.patch.dict(os.environ, self.environment):
            with self.assertRaisesRegex(ValueError, "must increase"):
                recommendations.sign(self.source, destination, self.certificate,
                                     expected_certificate_sha256=self.fingerprint)
        self.assertEqual(destination.read_bytes(), original)
        changed_source = self.work / "different-source.json"
        changed_source.write_text(json.dumps(payload(1, ["com.example.changed"])))
        with self.assertRaisesRegex(ValueError, "differ from"):
            recommendations.verify(self.envelope, self.certificate, payload=changed_source,
                                   expected_certificate_sha256=self.fingerprint)

    def test_new_revision_verifies_before_atomic_publication_and_rejects_rollback(self):
        source = self.work / "second-source.json"
        source.write_text(json.dumps(payload(2, ["com.example.new"])))
        destination = self.work / "updated.json"
        destination.write_bytes(self.envelope.read_bytes())
        with mock.patch.dict(os.environ, self.environment):
            result = recommendations.sign(source, destination, self.certificate,
                                          expected_certificate_sha256=self.fingerprint)
        self.assertEqual(result.rules_version, 2)
        recommendations.verify(destination, self.certificate, payload=source, previous=self.envelope,
                               expected_certificate_sha256=self.fingerprint)
        with self.assertRaisesRegex(ValueError, "roll back"):
            recommendations.verify(self.envelope, self.certificate, previous=destination,
                                   expected_certificate_sha256=self.fingerprint)

    def test_wrong_keystore_identity_cannot_replace_existing_catalogue(self):
        destination = self.work / "wrong-key-output.json"
        original = self.envelope.read_bytes()
        destination.write_bytes(original)
        source = self.work / "wrong-key-source.json"
        source.write_text(json.dumps(payload(2)))
        with mock.patch.dict(os.environ, {**self.environment, "FLOW_DATA_KEY_ALIAS": "other-test-only"}):
            with self.assertRaisesRegex(ValueError, "signature operation"):
                recommendations.sign(source, destination, self.certificate,
                                     expected_certificate_sha256=self.fingerprint)
        self.assertEqual(destination.read_bytes(), original)
        self.assertFalse(destination.with_name(f".{destination.name}.lock").exists())

    def test_lock_and_concurrent_newer_output_are_not_bypassed_by_explicit_previous(self):
        source = self.work / "lock-source.json"
        source.write_text(json.dumps(payload(2)))
        destination = self.work / "locked.json"
        destination.write_bytes(self.envelope.read_bytes())
        lock = destination.with_name(f".{destination.name}.lock")
        lock.write_bytes(b"another writer")
        try:
            with self.assertRaisesRegex(ValueError, "output lock"):
                recommendations.sign(source, destination, self.certificate, previous=self.envelope,
                                     expected_certificate_sha256=self.fingerprint)
            self.assertEqual(lock.read_bytes(), b"another writer")
        finally:
            lock.unlink()
        with mock.patch.dict(os.environ, self.environment):
            recommendations.sign(source, destination, self.certificate,
                                 expected_certificate_sha256=self.fingerprint)
            original = destination.read_bytes()
            with self.assertRaisesRegex(ValueError, "must increase"):
                recommendations.sign(source, destination, self.certificate, previous=self.envelope,
                                     expected_certificate_sha256=self.fingerprint)
        self.assertEqual(destination.read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
