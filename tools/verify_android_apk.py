#!/usr/bin/env python3
"""Post-build APK checks via Android SDK aapt; no device required."""
import argparse
from pathlib import Path
import subprocess
import sys
import os
import shutil
import re
import zipfile
sys.path.insert(0, str(Path(__file__).resolve().parent))
from fetch_xray_android import verify_elf_16k


QR_IMPORT_VERSION_CODE = 35
QR_ACTIVITY = 'shop.pushok.flow.WireGuardQrActivity'
XRAY_VERSION_CODE = 36
XRAY_SERVICE = 'shop.pushok.flow.XrayVpnService'
STORAGE_PERMISSIONS = {
    'android.permission.READ_EXTERNAL_STORAGE',
    'android.permission.WRITE_EXTERNAL_STORAGE',
    'android.permission.MANAGE_EXTERNAL_STORAGE',
    'android.permission.READ_MEDIA_IMAGES',
    'android.permission.READ_MEDIA_VIDEO',
    'android.permission.READ_MEDIA_VISUAL_USER_SELECTED',
}


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


def element_attributes(tree: str, tag: str) -> list[str]:
    """Read each element's own attributes, never a nested element's attributes."""
    result = []
    current = None
    for line in tree.splitlines():
        element = re.match(r'^\s*E: ([\w-]+)(?:\s|$)', line)
        if element:
            current = [] if element[1] == tag else None
            if current is not None:
                result.append(current)
        elif current is not None and re.match(r'^\s*A: ', line):
            current.append(line)
    return ['\n'.join(attributes) for attributes in result]


def attribute_value(attributes: str, name: str) -> str | None:
    matches = re.findall(
        rf'^\s*A: android:{re.escape(name)}(?:\([^)]*\))?=(.*)$',
        attributes, re.MULTILINE)
    return matches[0] if len(matches) == 1 else None


def string_attribute(attributes: str, name: str) -> str | None:
    value = attribute_value(attributes, name)
    match = re.match(r'^"([^"]*)"(?:\s|$)', value or '')
    return match[1] if match else None


def is_false_attribute(attributes: str, name: str) -> bool:
    value = attribute_value(attributes, name)
    return bool(re.match(r'^\(type 0x12\)0x0\b', value or ''))


def check_qr_import_manifest(tree: str, permissions: set[str]) -> None:
    if 'android.permission.CAMERA' not in permissions:
        raise ValueError('CAMERA permission not declared for QR import')
    if permissions & STORAGE_PERMISSIONS:
        raise ValueError('QR image import must not request broad storage or gallery permissions')

    # aapt may print a relative component name before/after manifest merging.
    scanner_names = {QR_ACTIVITY, '.WireGuardQrActivity', 'WireGuardQrActivity'}
    activities = element_attributes(tree, 'activity')
    if any(string_attribute(attributes, 'name') == 'com.journeyapps.barcodescanner.CaptureActivity'
           for attributes in activities):
        raise ValueError('Bundled default QR scanner must be removed from merged manifest')
    scanners = [attributes for attributes in activities
                if string_attribute(attributes, 'name') in scanner_names]
    if len(scanners) != 1:
        raise ValueError('Expected exactly one app-owned WireGuard QR scanner activity')
    if not is_false_attribute(scanners[0], 'exported'):
        raise ValueError('WireGuard QR scanner must be explicitly exported=false')

    # An exported alias would expose the same otherwise private scanner.
    for alias in element_attributes(tree, 'activity-alias'):
        if (string_attribute(alias, 'targetActivity') in scanner_names
                and not is_false_attribute(alias, 'exported')):
            raise ValueError('WireGuard QR scanner alias must be explicitly exported=false')

    camera_features = []
    for attributes in element_attributes(tree, 'uses-feature'):
        name = string_attribute(attributes, 'name')
        if name == 'android.hardware.camera' or (name or '').startswith('android.hardware.camera.'):
            if not is_false_attribute(attributes, 'required'):
                raise ValueError('Camera hardware features must be explicitly required=false')
            camera_features.append(name)
    # CAMERA implies both features unless the manifest explicitly makes them optional.
    for name in ('android.hardware.camera', 'android.hardware.camera.autofocus'):
        if camera_features.count(name) != 1:
            raise ValueError(f'Expected one optional camera hardware feature: {name}')


def check_apk(path: Path, aapt: str | None = None) -> None:
    if not path.is_file() or path.stat().st_size == 0:
        raise ValueError('Missing/empty APK')
    aapt = aapt or find_aapt()
    result = subprocess.run([aapt, 'dump', 'badging', str(path)], capture_output=True, text=True, check=True)
    package = re.findall(r"^package:\s+name='([^']+)'([^\r\n]*)$", result.stdout, re.MULTILINE)
    if len(package) != 1 or package[0][0] != 'shop.pushok.flow':
        raise ValueError('Unexpected package identifier')
    version_codes = re.findall(r"\bversionCode='([^']*)'", package[0][1])
    if len(version_codes) != 1 or not re.fullmatch(r'[1-9][0-9]*', version_codes[0]):
        raise ValueError('APK versionCode missing or invalid')
    version_code = int(version_codes[0])
    permissions = subprocess.run([aapt, 'dump', 'permissions', str(path)], capture_output=True, text=True, check=True)
    declared_permissions = set(re.findall(
        r"^uses-permission(?:-sdk-[\w]+)?:\s+name=['\"]([^'\"]+)['\"]",
        permissions.stdout, re.MULTILINE))
    if 'android.permission.INTERNET' not in declared_permissions:
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
    if version_code >= QR_IMPORT_VERSION_CODE:
        check_qr_import_manifest(manifest.stdout, declared_permissions)
        print('APK private QR scanner, camera permission and optional hardware checks passed')
    if version_code >= XRAY_VERSION_CODE:
        check_xray_manifest(manifest.stdout, declared_permissions)
        check_xray_libraries(path)
        print('APK isolated Xray service, three native ABIs, ELF 16 KiB pages and licenses verified')
    print('APK package, INTERNET and WireGuard VPN service checks passed')


def check_xray_manifest(tree: str, permissions: set[str]) -> None:
    names = {XRAY_SERVICE, '.XrayVpnService', 'XrayVpnService'}
    services = [attributes for attributes in element_attributes(tree, 'service')
                if string_attribute(attributes, 'name') in names]
    if len(services) != 1 or not is_false_attribute(services[0], 'exported') or \
            string_attribute(services[0], 'permission') != 'android.permission.BIND_VPN_SERVICE':
        raise ValueError('Xray service must be single, private and protected by BIND_VPN_SERVICE')
    if string_attribute(services[0], 'process') not in (':xray', 'shop.pushok.flow:xray'):
        raise ValueError('Xray Go runtime must run in its own process')
    foreground = attribute_value(services[0], 'foregroundServiceType') or ''
    if not re.match(r'^(?:\(type 0x1[01]\)0x40000000\b|"specialUse")', foreground):
        raise ValueError('Xray service foreground type must be specialUse')
    if not {'android.permission.FOREGROUND_SERVICE', 'android.permission.FOREGROUND_SERVICE_SPECIAL_USE',
            'android.permission.ACCESS_NETWORK_STATE'} <= permissions:
        raise ValueError('Xray foreground or network permissions missing')


def check_xray_libraries(path: Path) -> None:
    with zipfile.ZipFile(path) as apk:
        for abi in ('arm64-v8a', 'armeabi-v7a', 'x86_64'):
            name = f'lib/{abi}/libgojni.so'
            try: data = apk.read(name)
            except KeyError as error: raise ValueError(f'Xray native library missing for {abi}') from error
            verify_elf_16k(data)
        for name in ('libXray-MIT.txt', 'xray-core-MPL-2.0.txt', 'xray-sources.txt'):
            try: notice = apk.read(f'assets/licenses/{name}')
            except KeyError as error: raise ValueError('Xray redistribution notice missing from APK') from error
            if not notice:
                raise ValueError('Empty Xray redistribution notice')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('apk', type=Path)
    args = parser.parse_args()
    try:
        check_apk(args.apk)
    except (ValueError, OSError, subprocess.CalledProcessError) as err:
        print(f'APK validation failed: {err}', file=sys.stderr)
        sys.exit(1)
