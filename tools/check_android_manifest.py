#!/usr/bin/env python3
"""Fail fast on an unsafe legacy WireGuard VpnService declaration.
The WireGuard AAR contributes its own non-exported service via manifest merge.
"""
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ANDROID = '{http://schemas.android.com/apk/res/android}'
NAME = 'com.wireguard.android.backend.GoBackend$VpnService'


def validate(path: Path) -> None:
    tree = ET.parse(path)
    app = tree.getroot().find('application')
    if app is None:
        raise ValueError('Android manifest has no application element')
    services = [s for s in app.findall('service') if s.get(ANDROID + 'name') == NAME]
    if services:
        raise ValueError('App manifest redeclares WireGuard VPN service; use the library manifest')
    if app.get(ANDROID + 'allowBackup') != 'false':
        raise ValueError('Android backup must be disabled for encrypted on-device profiles')


if __name__ == '__main__':
    try:
        validate(ROOT / 'android/app/src/main/AndroidManifest.xml')
    except (ValueError, ET.ParseError, OSError) as exc:
        print(f'Invalid manifest: {exc}', file=sys.stderr)
        sys.exit(1)
    print('App manifest is compatible with WireGuard service manifest merge')