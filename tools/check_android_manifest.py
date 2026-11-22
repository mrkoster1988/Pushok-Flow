#!/usr/bin/env python3
"""Fail fast on unsafe profile storage, service merge or QR scanner declarations."""
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ANDROID = '{http://schemas.android.com/apk/res/android}'
NAME = 'com.wireguard.android.backend.GoBackend$VpnService'
SCANNER = 'shop.pushok.flow.WireGuardQrActivity'
GENERIC_SCANNER = 'com.journeyapps.barcodescanner.CaptureActivity'
TOOLS = '{http://schemas.android.com/tools}'
MEDIA_PERMISSIONS = {
    'android.permission.READ_EXTERNAL_STORAGE', 'android.permission.WRITE_EXTERNAL_STORAGE',
    'android.permission.MANAGE_EXTERNAL_STORAGE', 'android.permission.READ_MEDIA_IMAGES',
    'android.permission.READ_MEDIA_VIDEO', 'android.permission.READ_MEDIA_AUDIO',
    'android.permission.READ_MEDIA_VISUAL_USER_SELECTED',
}


def activity_name(name: str) -> str:
    if name.startswith('.'):
        return 'shop.pushok.flow' + name
    return name if '.' in name else 'shop.pushok.flow.' + name


def validate(path: Path) -> None:
    tree = ET.parse(path)
    manifest = tree.getroot()
    app = manifest.find('application')
    if app is None:
        raise ValueError('Android manifest has no application element')
    services = [s for s in app.findall('service') if s.get(ANDROID + 'name') == NAME]
    if services:
        raise ValueError('App manifest redeclares WireGuard VPN service; use the library manifest')
    if app.get(ANDROID + 'allowBackup') != 'false':
        raise ValueError('Android backup must be disabled for encrypted on-device profiles')
    permissions = {item.get(ANDROID + 'name') for tag in ('uses-permission', 'uses-permission-sdk-23')
                   for item in manifest.findall(tag)}
    if 'android.permission.CAMERA' not in permissions:
        raise ValueError('QR scanner requires the CAMERA permission declaration')
    if permissions & MEDIA_PERMISSIONS:
        raise ValueError('QR image import must use the document picker without broad media permissions')
    features = {item.get(ANDROID + 'name'): item.get(ANDROID + 'required')
                for item in manifest.findall('uses-feature')}
    for required in ('android.hardware.camera', 'android.hardware.camera.autofocus'):
        if features.get(required) != 'false':
            raise ValueError('Camera and autofocus features must be explicitly optional')
    for feature in manifest.findall('uses-feature'):
        name = feature.get(ANDROID + 'name', '')
        if (name == 'android.hardware.camera' or name.startswith('android.hardware.camera.')) and \
                feature.get(ANDROID + 'required') != 'false':
            raise ValueError('All camera features must be optional')
    scanners = [item for item in app.findall('activity')
                if activity_name(item.get(ANDROID + 'name', '')) == SCANNER]
    if len(scanners) != 1 or scanners[0].get(ANDROID + 'exported') != 'false' or \
            scanners[0].find('intent-filter') is not None:
        raise ValueError('QR scanner must be a single non-exported Activity without intent filters')
    if any(activity_name(item.get(ANDROID + 'targetActivity', '')) == SCANNER
           for item in app.findall('activity-alias')):
        raise ValueError('QR scanner cannot be exposed through an Activity alias')
    generics = [item for item in app.findall('activity')
                if item.get(ANDROID + 'name') == GENERIC_SCANNER]
    if len(generics) != 1 or generics[0].get(TOOLS + 'node') != 'remove':
        raise ValueError('The unused generic scanner must be removed during manifest merge')


if __name__ == '__main__':
    try:
        validate(ROOT / 'android/app/src/main/AndroidManifest.xml')
    except (ValueError, ET.ParseError, OSError) as exc:
        print(f'Invalid manifest: {exc}', file=sys.stderr)
        sys.exit(1)
    print('App manifest passed WireGuard service, profile storage and private QR scanner checks')
