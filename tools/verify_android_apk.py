#!/usr/bin/env python3
"""Post-build APK checks via Android SDK aapt; no device required."""
import argparse
from pathlib import Path
import subprocess
import sys
import os
import shutil
import re


def find_aapt() -> str:
    existing = shutil.which('aapt')
    if existing:
        return existing
    sdk = os.environ.get('ANDROID_HOME') or os.environ.get('ANDROID_SDK_ROOT')
    if sdk:
        candidates = sorted((Path(sdk) / 'build-tools').glob('*/aapt'), reverse=True)
        if candidates:
            return str(candidates[0])
    raise FileNotFoundError('Android SDK build-tools aapt missing')


def check_apk(path: Path, aapt: str | None = None) -> None:
    if not path.is_file() or path.stat().st_size == 0:
        raise ValueError('Missing/empty APK')
    aapt = aapt or find_aapt()
    result = subprocess.run([aapt, 'dump', 'badging', str(path)], capture_output=True, text=True, check=True)
    if "package: name='shop.pushok.flow'" not in result.stdout:
        raise ValueError('Unexpected package identifier')
    permissions = subprocess.run([aapt, 'dump', 'permissions', str(path)], capture_output=True, text=True, check=True)
    if 'android.permission.INTERNET' not in permissions.stdout:
        raise ValueError('INTERNET permission not declared in APK')
    manifest = subprocess.run([aapt, 'dump', 'xmltree', str(path), 'AndroidManifest.xml'], capture_output=True, text=True, check=True)
    NAME = 'com.wireguard.android.backend.GoBackend$VpnService'
    if NAME not in manifest.stdout:
        raise ValueError('WireGuard VPN service absent from merged manifest')
    # Inspect the complete service element, regardless of attribute order.
    lines = manifest.stdout.splitlines()
    service_blocks = []
    for i, line in enumerate(lines):
        m = re.match(r'^(\s*)E: service\s', line)
        if not m:
            continue
        indent = len(m.group(1))
        block = [line]
        for following in lines[i + 1:]:
            next_element = re.match(r'^(\s*)E: ', following)
            if next_element and len(next_element.group(1)) <= indent:
                break
            block.append(following)
        if NAME in '\n'.join(block):
            service_blocks.append('\n'.join(block))
    if len(service_blocks) != 1:
        raise ValueError('Expected exactly one WireGuard VPN service')
    service = service_blocks[0]
    if 'android.permission.BIND_VPN_SERVICE' not in service:
        raise ValueError('WireGuard service must require BIND_VPN_SERVICE on its own declaration')
    if not re.search(r'android:exported\([^)]*\)=\(type 0x12\)0x0\b', service):
        raise ValueError('WireGuard service not explicitly exported=false; inspect merged manifest')
    print('APK package, INTERNET and WireGuard VPN service checks passed')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('apk', type=Path)
    args = parser.parse_args()
    try:
        check_apk(args.apk)
    except (ValueError, OSError, subprocess.CalledProcessError) as err:
        print(f'APK validation failed: {err}', file=sys.stderr)
        sys.exit(1)