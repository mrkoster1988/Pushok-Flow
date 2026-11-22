#!/usr/bin/env python3
"""Stage a verified release APK and its public in-app-update manifest."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import sys

from verify_release_apk import MAX_APK_BYTES, PACKAGE, read_version
from restore_public_release import ABIS, apk_name, read_json, verification_name


REPOSITORY = "mrkoster1988/Pushok-Flow"


def validate_previous_manifest(current: dict, previous: dict) -> None:
    """Reject accidental key replacement or a downgrade of the latest channel."""
    if previous.get("schemaVersion") != 1 or previous.get("packageName") != PACKAGE:
        raise ValueError("Previous update channel has an unexpected identity")
    previous_code = previous.get("versionCode")
    if type(previous_code) is not int or current["versionCode"] <= previous_code:
        raise ValueError("A release must increase versionCode above the latest published build")
    if previous.get("certificateSha256") != current["certificateSha256"]:
        raise ValueError("Persistent signing certificate differs from the published update channel")


def build_manifest(apk: Path, verified: dict, pubspec: Path, abi: str | None = None) -> dict:
    if type(verified) is not dict:
        raise ValueError("Invalid release verification report")
    version, code = read_version(pubspec)
    if abi is not None and abi not in ABIS:
        raise ValueError("Unexpected APK architecture")
    if verified.get('abi') != abi:
        raise ValueError("Verified APK architecture differs from its intended variant")
    expected = {"packageName": PACKAGE, "versionName": version, "versionCode": code, "minSdk": 24}
    if any(verified.get(name) != value for name, value in expected.items()):
        raise ValueError("Verified APK identity does not match the current release")
    certificate = verified.get("certificateSha256")
    if not isinstance(certificate, str) or not re.fullmatch(r"[0-9a-f]{64}", certificate):
        raise ValueError("A verified release certificate is required")
    size = apk.stat().st_size
    if not 0 < size <= MAX_APK_BYTES or type(verified.get("sizeBytes")) is not int or verified["sizeBytes"] != size:
        raise ValueError("Release APK size changed after verification")
    with apk.open("rb") as source:
        digest = hashlib.file_digest(source, "sha256").hexdigest()
    if verified.get("sha256") != digest:
        raise ValueError("Release APK bytes changed after signature verification")
    return {
        "schemaVersion": 1,
        **expected,
        "apkUrl": f"https://github.com/{REPOSITORY}/releases/download/v{version}/" + apk_name(version, abi),
        "sha256": digest,
        "sizeBytes": size,
        "certificateSha256": certificate,
    }


def stage(apk: Path, verified_path: Path, pubspec: Path, output: Path,
          variants_dir: Path | None = None) -> dict:
    verified = json.loads(verified_path.read_text(encoding="utf-8"))
    if not isinstance(verified, dict):
        raise ValueError("Invalid release verification report")
    manifest = build_manifest(apk, verified, pubspec)
    payloads = [(apk, manifest, None)]
    if variants_dir is not None:
        for abi in ABIS:
            variant_apk = variants_dir / apk_name(manifest['versionName'], abi)
            report = read_json(variants_dir / verification_name(abi))
            variant = build_manifest(variant_apk, report, pubspec, abi)
            for key in ('packageName', 'versionName', 'versionCode', 'minSdk', 'certificateSha256'):
                if variant[key] != manifest[key]:
                    raise ValueError('Variant identity differs from universal APK: ' + key)
            payloads.append((variant_apk, variant, abi))
    # Validate every input before creating or replacing output files. The sole
    # public manifest remains schema 1 and always describes the universal APK.
    output.mkdir(parents=True, exist_ok=True)
    for source, metadata, abi in payloads:
        name = apk_name(metadata['versionName'], abi)
        destination = output / name
        if source.resolve() != destination.resolve():
            shutil.copyfile(source, destination)
        (output / (name + ".sha256")).write_text(f"{metadata['sha256']}  {name}\n", encoding="utf-8")
    (output / "update.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    return manifest


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apk", type=Path, required=True)
    parser.add_argument("--verified", type=Path, required=True)
    parser.add_argument("--pubspec", type=Path, default=Path("pubspec.yaml"))
    parser.add_argument("--output", type=Path, default=Path("dist"))
    parser.add_argument("--variants-dir", type=Path,
                        help="Directory with all three signed ABI APKs and verified-release-<abi>.json reports")
    args = parser.parse_args()
    try:
        manifest = stage(args.apk, args.verified, args.pubspec, args.output, args.variants_dir)
    except (ValueError, OSError, TypeError) as error:
        print(f"Update manifest creation failed: {error}", file=sys.stderr)
        return 1
    print(f"Staged Pushok Flow {manifest['versionName']} ({manifest['versionCode']}) and update.json")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
