#!/usr/bin/env python3
"""Sign and verify the bounded, data-only Android route recommendation channel.

The public CLI pins the existing Pushok Flow signing certificate. Signing uses
the already-held keystore through environment variables consumed by the Java
helper; neither this tool nor CI creates an Android signing identity.
"""
from __future__ import annotations

import argparse
import base64
import binascii
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


CERTIFICATE_SHA256 = "8b4114881116a920c3351b503052ac27078fdbbfcae1ace27f1af8245ebb7047"
DOMAIN = b"Pushok Flow route recommendations v1\n"
MAX_ENVELOPE_BYTES = 131072
MAX_PAYLOAD_BYTES = 65536
MAX_PACKAGES = 256
MAX_PACKAGE_LENGTH = 255
MAX_RULES_VERSION = 2147483647
MIN_SIGNATURE_BYTES = 256
MAX_SIGNATURE_BYTES = 1024
_PACKAGE = re.compile(r"[A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)+", re.ASCII)
_DIGEST = re.compile(r"[0-9a-f]{64}", re.ASCII)
_PAYLOAD_KEYS = {"schema_version", "rules_version", "recommended_bypass_packages"}
_ENVELOPE_KEYS = {"schema_version", "payload", "signature"}
_SIGNING_ENV = ("FLOW_DATA_KEYSTORE", "FLOW_DATA_STORE_PASSWORD",
                "FLOW_DATA_KEY_PASSWORD", "FLOW_DATA_KEY_ALIAS")


@dataclass(frozen=True)
class VerifiedRecommendations:
    rules_version: int
    packages: tuple[str, ...]
    payload: bytes
    signature: bytes

    @property
    def payload_sha256(self) -> str:
        return hashlib.sha256(self.payload).hexdigest()


def _read_bounded(path: Path, maximum: int) -> bytes:
    with path.open("rb") as source:
        data = source.read(maximum + 1)
    if not data or len(data) > maximum:
        raise ValueError("Recommendation file is empty or exceeds its size limit")
    return data


def _unique_object(pairs: list[tuple[str, object]]) -> dict:
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Duplicate JSON field in recommendation data")
        result[key] = value
    return result


def _reject_constant(_: str) -> object:
    raise ValueError("Non-finite JSON number in recommendation data")


def _json_document(data: bytes, maximum: int) -> object:
    if not isinstance(data, bytes) or not data or len(data) > maximum:
        raise ValueError("Recommendation document exceeds its size limit")
    try:
        return json.loads(data.decode("utf-8"), object_pairs_hook=_unique_object,
                          parse_constant=_reject_constant)
    except (UnicodeError, json.JSONDecodeError, RecursionError) as error:
        raise ValueError("Malformed recommendation JSON") from error


def validate_payload(document: object) -> dict:
    if not isinstance(document, dict) or set(document) != _PAYLOAD_KEYS:
        raise ValueError("Unexpected recommendation payload fields")
    if type(document["schema_version"]) is not int or document["schema_version"] != 1:
        raise ValueError("Unsupported recommendation schema")
    version = document["rules_version"]
    if type(version) is not int or not 1 <= version <= MAX_RULES_VERSION:
        raise ValueError("Invalid recommendation version")
    packages = document["recommended_bypass_packages"]
    if not isinstance(packages, list) or len(packages) > MAX_PACKAGES:
        raise ValueError("Invalid recommendation package list")
    seen = set()
    for package in packages:
        if (not isinstance(package, str) or not 1 <= len(package) <= MAX_PACKAGE_LENGTH
                or _PACKAGE.fullmatch(package) is None or package in seen):
            raise ValueError("Invalid or duplicate recommendation package")
        seen.add(package)
    return {"schema_version": 1, "rules_version": version,
            "recommended_bypass_packages": sorted(seen)}


def canonical_payload(document: object) -> bytes:
    validated = validate_payload(document)
    encoded = (json.dumps(validated, sort_keys=True, ensure_ascii=True,
                          separators=(",", ":")) + "\n").encode("utf-8")
    if len(encoded) > MAX_PAYLOAD_BYTES:
        raise ValueError("Recommendation payload exceeds its size limit")
    return encoded


def read_payload(path: Path) -> bytes:
    return canonical_payload(_json_document(_read_bounded(path, MAX_PAYLOAD_BYTES),
                                            MAX_PAYLOAD_BYTES))


def _base64_bytes(value: object, maximum: int) -> bytes:
    if (not isinstance(value, str) or not value
            or len(value) > 4 * ((maximum + 2) // 3)):
        raise ValueError("Invalid recommendation base64 field")
    try:
        decoded = base64.b64decode(value, validate=True)
    except (ValueError, binascii.Error) as error:
        raise ValueError("Invalid recommendation base64 field") from error
    if (not decoded or len(decoded) > maximum
            or base64.b64encode(decoded).decode("ascii") != value):
        raise ValueError("Non-canonical recommendation base64 field")
    return decoded


def decode_envelope(data: bytes) -> tuple[bytes, bytes]:
    document = _json_document(data, MAX_ENVELOPE_BYTES)
    if not isinstance(document, dict) or set(document) != _ENVELOPE_KEYS:
        raise ValueError("Unexpected recommendation envelope fields")
    if type(document["schema_version"]) is not int or document["schema_version"] != 1:
        raise ValueError("Unsupported recommendation envelope schema")
    payload = _base64_bytes(document["payload"], MAX_PAYLOAD_BYTES)
    signature = _base64_bytes(document["signature"], MAX_SIGNATURE_BYTES)
    if len(signature) < MIN_SIGNATURE_BYTES:
        raise ValueError("Invalid recommendation signature size")
    return payload, signature


def encode_envelope(payload: bytes, signature: bytes) -> bytes:
    document = {"schema_version": 1,
                "payload": base64.b64encode(payload).decode("ascii"),
                "signature": base64.b64encode(signature).decode("ascii")}
    encoded = (json.dumps(document, sort_keys=True, indent=2) + "\n").encode("utf-8")
    # Apply the same envelope limits to locally generated output.
    decode_envelope(encoded)
    return encoded


def _signature_operation(mode: str, certificate: Path, payload: Path, signature: Path,
                         expected_certificate_sha256: str) -> None:
    if mode not in {"sign", "verify"} or _DIGEST.fullmatch(expected_certificate_sha256) is None:
        raise ValueError("Invalid signature verification request")
    helper = Path(__file__).with_name("RecommendationSignature.java")
    environment = os.environ.copy()
    if mode == "verify":
        for name in _SIGNING_ENV:
            environment.pop(name, None)
    command = ["java", str(helper), mode, str(certificate), str(payload), str(signature),
               expected_certificate_sha256]
    try:
        result = subprocess.run(command, env=environment, capture_output=True,
                                text=True, timeout=45, check=False)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise ValueError("Java signature verification is unavailable") from error
    if result.returncode != 0:
        # Helper/compiler output is deliberately not reflected: sign environments
        # contain credentials, and failed tools must never print them indirectly.
        raise ValueError("Recommendation signature operation failed")


def verify_bytes(data: bytes, certificate: Path, *,
                 expected_certificate_sha256: str = CERTIFICATE_SHA256) -> VerifiedRecommendations:
    payload, signature = decode_envelope(data)
    with tempfile.TemporaryDirectory(prefix="pushok-recommendations-verify-") as directory:
        work = Path(directory)
        payload_path, signature_path = work / "payload.json", work / "signature.bin"
        payload_path.write_bytes(payload)
        signature_path.write_bytes(signature)
        _signature_operation("verify", certificate, payload_path, signature_path,
                             expected_certificate_sha256)
    # Authenticate the exact bytes before interpreting the payload.
    document = validate_payload(_json_document(payload, MAX_PAYLOAD_BYTES))
    return VerifiedRecommendations(document["rules_version"],
                                   tuple(document["recommended_bypass_packages"]),
                                   payload, signature)


def require_revision(candidate: VerifiedRecommendations, previous: VerifiedRecommendations,
                     *, allow_identical: bool) -> None:
    if candidate.rules_version < previous.rules_version:
        raise ValueError("Recommendation version would roll back the channel")
    if candidate.rules_version == previous.rules_version:
        if not allow_identical or candidate.payload != previous.payload:
            raise ValueError("Recommendation version must increase for changed data")


def verify(envelope: Path, certificate: Path, *, payload: Path | None = None,
           previous: Path | None = None,
           expected_certificate_sha256: str = CERTIFICATE_SHA256) -> VerifiedRecommendations:
    candidate = verify_bytes(_read_bounded(envelope, MAX_ENVELOPE_BYTES), certificate,
                             expected_certificate_sha256=expected_certificate_sha256)
    if payload is not None and candidate.payload != read_payload(payload):
        raise ValueError("Signed recommendation bytes differ from the source payload")
    if previous is not None:
        baseline = verify_bytes(_read_bounded(previous, MAX_ENVELOPE_BYTES), certificate,
                                expected_certificate_sha256=expected_certificate_sha256)
        require_revision(candidate, baseline, allow_identical=True)
    return candidate


def _atomic_write(output: Path, data: bytes, expected: bytes | None) -> None:
    temporary: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(mode="wb", prefix=f".{output.name}.",
                                         dir=output.parent, delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        observed = _read_bounded(output, MAX_ENVELOPE_BYTES) if output.exists() else None
        if observed != expected:
            raise ValueError("Recommendation output changed during signing")
        os.replace(temporary, output)
        temporary = None
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def sign(payload: Path, output: Path, certificate: Path, *, previous: Path | None = None,
         expected_certificate_sha256: str = CERTIFICATE_SHA256) -> VerifiedRecommendations:
    encoded_payload = read_payload(payload)
    output.parent.mkdir(parents=True, exist_ok=True)
    lock_path = output.with_name(f".{output.name}.lock")
    try:
        lock = os.open(lock_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError as error:
        raise ValueError("Another recommendation publication holds the output lock") from error
    try:
        os.close(lock)
        original = _read_bounded(output, MAX_ENVELOPE_BYTES) if output.exists() else None
        baselines = []
        if original is not None:
            baselines.append(verify_bytes(original, certificate,
                                          expected_certificate_sha256=expected_certificate_sha256))
        if previous is not None and previous.resolve() != output.resolve():
            baselines.append(verify_bytes(_read_bounded(previous, MAX_ENVELOPE_BYTES), certificate,
                                          expected_certificate_sha256=expected_certificate_sha256))
        elif previous is not None and original is None:
            raise ValueError("Previous recommendation envelope does not exist")
        # Reject a rollback before the helper loads any private key material.
        offered_version = validate_payload(_json_document(encoded_payload, MAX_PAYLOAD_BYTES))["rules_version"]
        if any(offered_version <= baseline.rules_version for baseline in baselines):
            raise ValueError("A signed publication must increase the recommendation version")
        with tempfile.TemporaryDirectory(prefix="pushok-recommendations-sign-") as directory:
            work = Path(directory)
            payload_path, signature_path = work / "payload.json", work / "signature.bin"
            payload_path.write_bytes(encoded_payload)
            _signature_operation("sign", certificate, payload_path, signature_path,
                                 expected_certificate_sha256)
            signature = _read_bounded(signature_path, MAX_SIGNATURE_BYTES)
            encoded = encode_envelope(encoded_payload, signature)
            candidate = verify_bytes(encoded, certificate,
                                     expected_certificate_sha256=expected_certificate_sha256)
        for baseline in baselines:
            require_revision(candidate, baseline, allow_identical=False)
        _atomic_write(output, encoded, original)
        return candidate
    finally:
        lock_path.unlink(missing_ok=True)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    signing = commands.add_parser("sign", help="Sign a new, strictly newer catalogue")
    signing.add_argument("--payload", type=Path, required=True)
    signing.add_argument("--output", type=Path, required=True)
    signing.add_argument("--certificate", type=Path, required=True)
    signing.add_argument("--previous", type=Path)
    checking = commands.add_parser("verify", help="Verify signature, schema and optional source/baseline")
    checking.add_argument("--envelope", type=Path, required=True)
    checking.add_argument("--certificate", type=Path, required=True)
    checking.add_argument("--payload", type=Path)
    checking.add_argument("--previous", type=Path)
    arguments = parser.parse_args(argv)
    try:
        if arguments.command == "sign":
            result = sign(arguments.payload, arguments.output, arguments.certificate,
                          previous=arguments.previous)
        else:
            result = verify(arguments.envelope, arguments.certificate,
                            payload=arguments.payload, previous=arguments.previous)
    except (ValueError, OSError) as error:
        print(f"Recommendation publication failed: {error}", file=sys.stderr)
        return 1
    print(f"Verified recommendations v{result.rules_version}: {len(result.packages)} packages, "
          f"payload SHA-256 {result.payload_sha256}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
