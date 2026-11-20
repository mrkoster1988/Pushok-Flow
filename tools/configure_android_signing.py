#!/usr/bin/env python3
"""Configure generated Android release builds from private CI environment only."""
import argparse
import base64
import binascii
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile


REQUIRED = (
    "PUSHOK_ANDROID_KEYSTORE_BASE64",
    "PUSHOK_ANDROID_KEYSTORE_PASSWORD",
    "PUSHOK_ANDROID_KEY_ALIAS",
    "PUSHOK_ANDROID_KEY_PASSWORD",
)
BEGIN = "// BEGIN PUSHOK_RELEASE_SIGNING"
END = "// END PUSHOK_RELEASE_SIGNING"
SIGNING_BLOCK = '''// BEGIN PUSHOK_RELEASE_SIGNING
android {
    signingConfigs {
        create("pushokRelease") {
            storeFile = file(requireNotNull(System.getenv("PUSHOK_ANDROID_KEYSTORE_FILE")) {
                "Pushok release keystore is not configured"
            })
            storePassword = requireNotNull(System.getenv("PUSHOK_ANDROID_KEYSTORE_PASSWORD")) {
                "Pushok release signing is not configured"
            }
            keyAlias = requireNotNull(System.getenv("PUSHOK_ANDROID_KEY_ALIAS")) {
                "Pushok release signing is not configured"
            }
            keyPassword = requireNotNull(System.getenv("PUSHOK_ANDROID_KEY_PASSWORD")) {
                "Pushok release signing is not configured"
            }
        }
    }
    buildTypes {
        getByName("release") {
            signingConfig = signingConfigs.getByName("pushokRelease")
            isDebuggable = false
        }
    }
}
// END PUSHOK_RELEASE_SIGNING
'''


def decode_keystore(environment: dict[str, str]) -> bytes:
    missing = [name for name in REQUIRED if not environment.get(name)]
    if missing:
        # Names are safe; values must never reach logs or exceptions.
        raise ValueError("Missing signing secrets: " + ", ".join(missing))
    encoded = "".join(environment[REQUIRED[0]].split())
    try:
        data = base64.b64decode(encoded, validate=True)
    except (binascii.Error, ValueError):
        raise ValueError("Release keystore is not valid base64") from None
    if not 128 <= len(data) <= 1024 * 1024:
        raise ValueError("Release keystore has an invalid size")
    return data


def patch_signing(source: str) -> str:
    if not re.search(r"\bandroid\s*\{", source):
        raise ValueError("Android Gradle configuration is missing")
    if source.count(BEGIN) != source.count(END) or source.count(BEGIN) > 1:
        raise ValueError("Android signing markers are invalid")
    source = re.sub(re.escape(BEGIN) + r".*?" + re.escape(END) + r"\n?",
                    "", source, flags=re.DOTALL)
    # Flutter's generated template signs release with debug by default.
    source = re.sub(
        r'(?m)^[ \t]*signingConfig\s*=\s*signingConfigs\.getByName\("debug"\)\s*$',
        "            // Release signing is supplied by the private CI configuration.",
        source,
    )
    return source.rstrip() + "\n\n" + SIGNING_BLOCK


def configure(root: Path, environment: dict[str, str]) -> dict[str, str]:
    data = decode_keystore(environment)
    gradle = root / "android/app/build.gradle.kts"
    patched = patch_signing(gradle.read_text(encoding="utf-8"))
    temporary_root = environment.get("RUNNER_TEMP")
    if not temporary_root or not Path(temporary_root).is_dir():
        raise ValueError("A private RUNNER_TEMP directory is required")
    keytool = shutil.which("keytool")
    if not keytool:
        raise ValueError("Java keytool is required to validate the release certificate")
    directory = Path(tempfile.mkdtemp(prefix="pushok-signing-", dir=temporary_root))
    directory.chmod(0o700)
    keystore = directory / "release.keystore"
    try:
        descriptor = os.open(keystore, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "wb") as output:
            output.write(data)
        result = subprocess.run(
            [keytool, "-exportcert", "-keystore", str(keystore),
             "-alias", environment["PUSHOK_ANDROID_KEY_ALIAS"],
             "-storepass:env", "PUSHOK_ANDROID_KEYSTORE_PASSWORD"],
            env={**os.environ, **environment}, capture_output=True, timeout=30,
        )
        if result.returncode != 0 or not result.stdout:
            raise ValueError("Release keystore certificate could not be read")
        certificate = hashlib.sha256(result.stdout).hexdigest()
        values = {
            "PUSHOK_ANDROID_KEYSTORE_FILE": str(keystore),
            "PUSHOK_ANDROID_CERTIFICATE_SHA256": certificate,
        }
        github_env = environment.get("GITHUB_ENV")
        if not github_env:
            raise ValueError("GITHUB_ENV is required to pass the protected keystore path")
        # Only the private file path and public certificate digest are exported.
        # Passwords and aliases stay in the explicitly scoped step environment.
        with Path(github_env).open("a", encoding="utf-8") as output:
            for name, value in values.items():
                if "\n" in value or "\r" in value:
                    raise ValueError("Invalid signing metadata")
                output.write(f"{name}={value}\n")
        gradle.write_text(patched, encoding="utf-8")
        return values
    except BaseException:
        shutil.rmtree(directory)
        raise


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    try:
        values = configure(args.root, dict(os.environ))
    except (ValueError, OSError, subprocess.SubprocessError):
        print("Release signing setup failed. Check the four configured signing secrets and CI environment.",
              file=sys.stderr)
        return 1
    print("Private release signing configured; certificate SHA-256: "
          + values["PUSHOK_ANDROID_CERTIFICATE_SHA256"])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
