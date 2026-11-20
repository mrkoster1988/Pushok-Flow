#!/usr/bin/env python3
"""Verify release identity, Android metadata and cryptographic APK signatures."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

from verify_android_apk import check_apk, find_aapt


PACKAGE = "shop.pushok.flow"
MAX_APK_BYTES = 200 * 1024 * 1024


def read_version(pubspec: Path) -> tuple[str, int]:
    matches = re.findall(r"(?m)^version:\s*(\d+\.\d+\.\d+)\+([1-9]\d*)\s*(?:#.*)?$",
                         pubspec.read_text(encoding="utf-8"))
    if len(matches) != 1:
        raise ValueError("Expected one stable versionName+versionCode in pubspec.yaml")
    version, code = matches[0]
    if any(str(int(part)) != part for part in version.split(".")) or int(code) > 2100000000:
        raise ValueError("Invalid Android release version")
    return version, int(code)


def parse_badging(text: str, version: str, code: int) -> dict[str, str | int]:
    package = re.search(r"(?m)^package:\s+name='([^']+)'\s+versionCode='([^']+)'\s+versionName='([^']*)'", text)
    minimum = re.search(r"(?m)^sdkVersion:'(\d+)'", text)
    if not package or package.groups() != (PACKAGE, str(code), version):
        raise ValueError("APK package/version differs from the intended release")
    if not minimum or int(minimum[1]) != 24:
        raise ValueError("Release APK must preserve minSdk 24")
    if re.search(r"(?m)^application-debuggable\b", text):
        raise ValueError("Debuggable APK cannot be released")
    return {"packageName": PACKAGE, "versionName": version,
            "versionCode": code, "minSdk": 24}


def parse_certificate(text: str, expected: str) -> str:
    if not re.fullmatch(r"[0-9a-f]{64}", expected):
        raise ValueError("Expected public signing-certificate SHA-256 is missing")
    certificates = re.findall(r"(?m)^Signer #\d+ certificate SHA-256 digest:\s*([0-9a-fA-F]{64})\s*$", text)
    if len(certificates) != 1 or certificates[0].lower() != expected:
        raise ValueError("APK signer differs from the configured persistent release key")
    if not re.search(r"(?m)^Verified using v2 scheme \(APK Signature Scheme v2\): true\s*$", text):
        raise ValueError("APK v2 signature verification is required for supported Android versions")
    return expected


def find_apksigner() -> str:
    executable = shutil.which("apksigner")
    if executable:
        return executable
    sdk = os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT")
    if sdk:
        candidates = sorted((Path(sdk) / "build-tools").glob("*/apksigner"), reverse=True)
        if candidates:
            return str(candidates[0])
    raise FileNotFoundError("Android SDK apksigner is missing")


def verify(apk: Path, pubspec: Path, expected_certificate: str) -> dict[str, str | int]:
    if not apk.is_file() or not 0 < apk.stat().st_size <= MAX_APK_BYTES:
        raise ValueError("Missing, empty or oversized release APK")
    version, code = read_version(pubspec)
    aapt = find_aapt()
    check_apk(apk, aapt)
    badging = subprocess.run([aapt, "dump", "badging", str(apk)],
                             capture_output=True, text=True, check=True)
    metadata = parse_badging(badging.stdout, version, code)
    signed = subprocess.run([find_apksigner(), "verify", "--verbose", "--print-certs", str(apk)],
                            capture_output=True, text=True, check=True)
    metadata["certificateSha256"] = parse_certificate(signed.stdout, expected_certificate)
    with apk.open("rb") as source:
        metadata["sha256"] = hashlib.file_digest(source, "sha256").hexdigest()
    metadata["sizeBytes"] = apk.stat().st_size
    return metadata


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("apk", type=Path)
    parser.add_argument("--pubspec", type=Path, default=Path("pubspec.yaml"))
    parser.add_argument("--expected-certificate-sha256", default=os.environ.get("PUSHOK_ANDROID_CERTIFICATE_SHA256", ""))
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        metadata = verify(args.apk, args.pubspec, args.expected_certificate_sha256)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print(f"Release APK verification failed: {error}", file=sys.stderr)
        return 1
    print("Release package, version, minSdk and non-debuggable state verified.")
    print("APK signature verified; certificate SHA-256: " + str(metadata["certificateSha256"]))
    print("APK SHA-256: " + str(metadata["sha256"]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
