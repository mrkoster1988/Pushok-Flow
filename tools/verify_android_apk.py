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
AUTO_UPDATE_VERSION_CODE = 37
COMPACT_NATIVE_VERSION_CODE = 39
ABI_VARIANT_VERSION_CODE = 40
FOREGROUND_DOWNLOAD_VERSION_CODE = 44
XRAY_NETWORK_HANDOVER_VERSION_CODE = 47
NATIVE_ABIS = ('arm64-v8a', 'armeabi-v7a', 'x86_64')
REQUIRED_NATIVE_LIBRARIES = (
    'libflutter.so', 'libapp.so', 'libgojni.so',
    'libwg-go.so', 'libwg.so', 'libwg-quick.so',
)
UPDATE_INSTALL_RECEIVER = 'shop.pushok.flow.UpdateInstallReceiver'
UPDATE_REPLACED_RECEIVER = 'shop.pushok.flow.UpdateReplacedReceiver'
UPDATE_PROVIDER = 'shop.pushok.flow.UpdateFileProvider'
WORK_JOB_SERVICE = 'androidx.work.impl.background.systemjob.SystemJobService'
WORK_INITIALIZER_PROVIDER = 'androidx.startup.InitializationProvider'
WORK_FOREGROUND_SERVICE = 'androidx.work.impl.foreground.SystemForegroundService'
DOWNLOAD_PERMISSIONS = {
    'android.permission.FOREGROUND_SERVICE',
    'android.permission.FOREGROUND_SERVICE_DATA_SYNC',
    'android.permission.POST_NOTIFICATIONS',
}
UPDATE_PERMISSIONS = {
    'android.permission.REQUEST_INSTALL_PACKAGES',
    'android.permission.UPDATE_PACKAGES_WITHOUT_USER_ACTION',
    'android.permission.ACCESS_NETWORK_STATE',
}
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


def element_blocks(tree: str, tag: str) -> list[str]:
    """Keep children within their own aapt xmltree element, excluding siblings."""
    lines = tree.splitlines()
    result = []
    for index, line in enumerate(lines):
        element = re.match(rf'^(\s*)E: {re.escape(tag)}(?:\s|$)', line)
        if not element:
            continue
        indent = len(element[1])
        block = [line]
        for following in lines[index + 1:]:
            next_element = re.match(r'^(\s*)E: ', following)
            if next_element and len(next_element[1]) <= indent:
                break
            block.append(following)
        result.append('\n'.join(block))
    return result


def has_attribute(attributes: str, name: str) -> bool:
    return bool(re.search(rf'^\s*A: android:{re.escape(name)}(?:\([^)]*\))?=',
                          attributes, re.MULTILINE))


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


def is_true_attribute(attributes: str, name: str) -> bool:
    value = attribute_value(attributes, name)
    return bool(re.match(r'^\(type 0x12\)0x(?:ffffffff|1)\b', value or ''))


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


def expected_native_abis(expected_abi: str | None = None) -> tuple[str, ...]:
    """Single-ABI checks must be explicitly requested, never inferred from a damaged APK."""
    if expected_abi is None:
        return NATIVE_ABIS
    if not isinstance(expected_abi, str) or expected_abi not in NATIVE_ABIS:
        raise ValueError('Unsupported expected native ABI')
    return (expected_abi,)


def check_apk(path: Path, aapt: str | None = None, expected_abi: str | None = None) -> None:
    expected_native_abis(expected_abi)
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
    debuggable = bool(re.search(r'^application-debuggable\b', result.stdout, re.MULTILINE))
    if expected_abi is not None:
        if version_code < ABI_VARIANT_VERSION_CODE or debuggable:
            raise ValueError('ABI-specific APK requires a non-debuggable release with versionCode >= 40')
        if re.search(r"\bsplit='[^']+'", package[0][1]):
            raise ValueError('An ABI-specific APK must be standalone, not an install-time split')
    permissions = subprocess.run([aapt, 'dump', 'permissions', str(path)], capture_output=True, text=True, check=True)
    declared_permissions = set(re.findall(
        r"^uses-permission(?:-sdk-[\w]+)?:\s+name=['\"]([^'\"]+)['\"]",
        permissions.stdout, re.MULTILINE))
    if 'android.permission.INTERNET' not in declared_permissions:
        raise ValueError('INTERNET permission not declared in APK')
    manifest = subprocess.run([aapt, 'dump', 'xmltree', str(path), 'AndroidManifest.xml'], capture_output=True, text=True, check=True)
    if expected_abi is not None and element_attributes(manifest.stdout, 'uses-split'):
        raise ValueError('An ABI-specific APK must not require another split APK')
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
        if version_code >= XRAY_NETWORK_HANDOVER_VERSION_CODE:
            check_xray_network_binding_permission(manifest.stdout, declared_permissions)
        if expected_abi is None:
            check_xray_libraries(path)
        else:
            check_xray_libraries(path, expected_abi)
        print('APK isolated Xray service, required native ABIs, ELF 16 KiB pages and licenses verified')
    if version_code >= AUTO_UPDATE_VERSION_CODE:
        check_update_manifest(manifest.stdout, declared_permissions)
        print('APK private update callbacks, persistent scheduler and install permissions verified')
    if version_code >= FOREGROUND_DOWNLOAD_VERSION_CODE:
        check_update_download_manifest(manifest.stdout, declared_permissions)
        print('APK private dataSync download service and notification permissions verified')
    # The separate JIT debug workflow has no AOT libapp.so. The persistent
    # release verifier independently rejects every debuggable APK.
    if version_code >= COMPACT_NATIVE_VERSION_CODE and not debuggable:
        if expected_abi is None:
            check_compact_native_packaging(path, manifest.stdout)
        else:
            check_compact_native_packaging(path, manifest.stdout, expected_abi)
        print('APK compressed native libraries, exact expected ABIs and extraction flag verified')
    print('APK package, INTERNET and WireGuard VPN service checks passed')


def check_update_manifest(tree: str, permissions: set[str]) -> None:
    """Gate the app's update surface and the essential merged WorkManager entry points."""
    if not UPDATE_PERMISSIONS <= permissions:
        raise ValueError('Automatic update permissions missing')
    declarations = element_attributes(tree, 'uses-permission')
    for name in sorted(UPDATE_PERMISSIONS):
        matches = [item for item in declarations if string_attribute(item, 'name') == name]
        if len(matches) != 1 or has_attribute(matches[0], 'maxSdkVersion'):
            raise ValueError('Update permission must be declared once without maxSdkVersion')

    def main_process(attributes: str, description: str) -> None:
        if (has_attribute(attributes, 'process') and
                string_attribute(attributes, 'process') != 'shop.pushok.flow'):
            raise ValueError(f'{description} must use the default app process')
        if has_attribute(attributes, 'enabled') and not is_true_attribute(attributes, 'enabled'):
            raise ValueError(f'{description} must not be disabled')

    applications = element_attributes(tree, 'application')
    if len(applications) != 1:
        raise ValueError('Expected exactly one application for updater')
    main_process(applications[0], 'Update application')

    def component(tag: str, name: str) -> tuple[str, str]:
        names = {name}
        if name.startswith('shop.pushok.flow.'):
            short = name.removeprefix('shop.pushok.flow.')
            names.update({short, '.' + short})
        matches = []
        for block in element_blocks(tree, tag):
            attributes = element_attributes(block, tag)[0]
            if string_attribute(attributes, 'name') in names:
                matches.append((block, attributes))
        if len(matches) != 1:
            raise ValueError(f'Expected exactly one {name}')
        main_process(matches[0][1], name)
        return matches[0]

    callback, attributes = component('receiver', UPDATE_INSTALL_RECEIVER)
    if not is_false_attribute(attributes, 'exported'):
        raise ValueError('Update install receiver must be explicitly exported=false')
    if element_blocks(callback, 'intent-filter'):
        raise ValueError('Update install callback must not have intent filters')

    replaced, attributes = component('receiver', UPDATE_REPLACED_RECEIVER)
    if not is_false_attribute(attributes, 'exported'):
        raise ValueError('Update replaced receiver must be explicitly exported=false')
    filters = element_blocks(replaced, 'intent-filter')
    if len(filters) != 1:
        raise ValueError('Update replaced receiver must have one MY_PACKAGE_REPLACED filter')
    actions = element_attributes(filters[0], 'action')
    children = re.findall(r'^\s*E: ([\w-]+)(?:\s|$)', filters[0], re.MULTILINE)
    if (children != ['intent-filter', 'action'] or len(actions) != 1 or
            string_attribute(actions[0], 'name') != 'android.intent.action.MY_PACKAGE_REPLACED'):
        raise ValueError('Update replaced receiver must handle only MY_PACKAGE_REPLACED')

    _, provider = component('provider', UPDATE_PROVIDER)
    if (not is_false_attribute(provider, 'exported') or
            not is_true_attribute(provider, 'grantUriPermissions') or
            string_attribute(provider, 'authorities') != 'shop.pushok.flow.updates'):
        raise ValueError('Update FileProvider must be private with explicit URI grants and own authority')

    # Check the stable trust boundaries, not every AndroidX service/receiver or
    # their resource-valued enabled flags. WorkManager manages those flags itself.
    job_blocks = [block for block in element_blocks(tree, 'service')
                  if string_attribute(element_attributes(block, 'service')[0], 'name') == WORK_JOB_SERVICE]
    if len(job_blocks) != 1:
        raise ValueError('Expected exactly one WorkManager SystemJobService')
    job = element_attributes(job_blocks[0], 'service')[0]
    if (not is_true_attribute(job, 'exported') or
            string_attribute(job, 'permission') != 'android.permission.BIND_JOB_SERVICE' or
            (has_attribute(job, 'process') and string_attribute(job, 'process') != 'shop.pushok.flow')):
        raise ValueError('WorkManager SystemJobService must be protected by BIND_JOB_SERVICE in app process')

    initializer, attributes = component('provider', WORK_INITIALIZER_PROVIDER)
    if (not is_false_attribute(attributes, 'exported') or
            string_attribute(attributes, 'authorities') != 'shop.pushok.flow.androidx-startup'):
        raise ValueError('WorkManager initializer provider must be private with own authority')
    metadata = [item for item in element_attributes(initializer, 'meta-data')
                if string_attribute(item, 'name') == 'androidx.work.WorkManagerInitializer']
    if len(metadata) != 1 or string_attribute(metadata[0], 'value') != 'androidx.startup':
        raise ValueError('WorkManager default initializer missing or duplicated')


def check_update_download_manifest(tree: str, permissions: set[str]) -> None:
    if not DOWNLOAD_PERMISSIONS <= permissions:
        raise ValueError('Foreground download permissions missing')
    declarations = element_attributes(tree, 'uses-permission')
    for name in sorted(DOWNLOAD_PERMISSIONS):
        matches = [item for item in declarations if string_attribute(item, 'name') == name]
        if len(matches) != 1 or has_attribute(matches[0], 'maxSdkVersion'):
            raise ValueError('Foreground download permission must be declared once without maxSdkVersion')
    services = [block for block in element_blocks(tree, 'service')
                if string_attribute(element_attributes(block, 'service')[0], 'name') == WORK_FOREGROUND_SERVICE]
    if len(services) != 1:
        raise ValueError('Expected exactly one WorkManager SystemForegroundService')
    attributes = element_attributes(services[0], 'service')[0]
    foreground = attribute_value(attributes, 'foregroundServiceType') or ''
    if not is_false_attribute(attributes, 'exported') or \
            not re.match(r'^(?:\(type 0x1[01]\)0x1\b|"dataSync")', foreground) or \
            (has_attribute(attributes, 'process') and string_attribute(attributes, 'process') != 'shop.pushok.flow') or \
            is_false_attribute(attributes, 'enabled') or element_blocks(services[0], 'intent-filter'):
        raise ValueError('WorkManager SystemForegroundService must be private dataSync in app process')


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


def check_xray_network_binding_permission(tree: str, permissions: set[str]) -> None:
    name = 'android.permission.CHANGE_NETWORK_STATE'
    if name not in permissions:
        raise ValueError('Xray physical network binding permission missing')
    declarations = [attributes for attributes in element_attributes(tree, 'uses-permission')
                    if string_attribute(attributes, 'name') == name]
    if len(declarations) != 1 or has_attribute(declarations[0], 'maxSdkVersion'):
        raise ValueError('Xray network binding permission must be declared once without maxSdkVersion')


def check_xray_libraries(path: Path, expected_abi: str | None = None) -> None:
    with zipfile.ZipFile(path) as apk:
        for abi in expected_native_abis(expected_abi):
            name = f'lib/{abi}/libgojni.so'
            try: data = apk.read(name)
            except KeyError as error: raise ValueError(f'Xray native library missing for {abi}') from error
            verify_elf_16k(data)
        for name in ('libXray-MIT.txt', 'xray-core-MPL-2.0.txt', 'xray-sources.txt'):
            try: notice = apk.read(f'assets/licenses/{name}')
            except KeyError as error: raise ValueError('Xray redistribution notice missing from APK') from error
            if not notice:
                raise ValueError('Empty Xray redistribution notice')


def check_compact_native_packaging(path: Path, tree: str, expected_abi: str | None = None) -> None:
    """Require complete compressed native entries and installer extraction metadata."""
    abis = expected_native_abis(expected_abi)
    applications = element_attributes(tree, 'application')
    if len(applications) != 1:
        raise ValueError('Expected exactly one application for native extraction')
    if not is_true_attribute(applications[0], 'extractNativeLibs'):
        raise ValueError('Compressed native libraries require explicit extractNativeLibs=true')

    with zipfile.ZipFile(path) as apk:
        entries = apk.infolist()
        names = {item.filename for item in entries}
        if len(names) != len(entries):
            raise ValueError('Duplicate APK ZIP entries are not supported')
        required = {f'lib/{abi}/{library}'
                    for abi in abis for library in REQUIRED_NATIVE_LIBRARIES}
        missing = required - names
        if missing:
            raise ValueError('Required native library missing: ' + sorted(missing)[0])
        actual_abis = set()
        # Apply the packaging contract to additional native dependencies too;
        # their introduction must not silently restore uncompressed downloads.
        for item in entries:
            if not (item.filename.startswith('lib/') and item.filename.endswith('.so')):
                continue
            parts = item.filename.split('/')
            if len(parts) != 3:
                raise ValueError('Unexpected native library path: ' + item.filename)
            actual_abis.add(parts[1])
            if item.flag_bits & 1:
                raise ValueError('Encrypted native libraries cannot be installed')
            if item.compress_type != zipfile.ZIP_DEFLATED:
                raise ValueError('Native libraries must use ZIP DEFLATE compression: ' + item.filename)
            if item.is_dir() or item.file_size <= 0 or item.compress_size <= 0:
                raise ValueError('Empty native library: ' + item.filename)
        if actual_abis != set(abis):
            raise ValueError('APK native ABI set differs from the explicitly expected architectures: '
                             + 'expected=' + ','.join(sorted(abis))
                             + '; actual=' + ','.join(sorted(actual_abis)))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('apk', type=Path)
    parser.add_argument('--abi', choices=NATIVE_ABIS,
                        help='Explicit standalone APK ABI; omitted requires the universal APK')
    args = parser.parse_args()
    try:
        check_apk(args.apk, expected_abi=args.abi)
    except (ValueError, OSError, subprocess.CalledProcessError) as err:
        print(f'APK validation failed: {err}', file=sys.stderr)
        sys.exit(1)
