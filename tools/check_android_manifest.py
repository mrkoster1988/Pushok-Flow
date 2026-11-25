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
XRAY_SERVICE = 'shop.pushok.flow.XrayVpnService'
MAIN_ACTIVITY = 'shop.pushok.flow.MainActivity'
UPDATE_PROVIDER = 'shop.pushok.flow.UpdateFileProvider'
UPDATE_INSTALL_RECEIVER = 'shop.pushok.flow.UpdateInstallReceiver'
UPDATE_REPLACED_RECEIVER = 'shop.pushok.flow.UpdateReplacedReceiver'
UPDATE_FOREGROUND_SERVICE = 'androidx.work.impl.foreground.SystemForegroundService'
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
    mains = [item for item in app.findall('activity')
             if activity_name(item.get(ANDROID + 'name', '')) == MAIN_ACTIVITY]
    if len(mains) != 1 or mains[0].get(ANDROID + 'exported') != 'true' or \
            mains[0].get(ANDROID + 'launchMode') != 'singleTop':
        raise ValueError('Subscription links require one exported singleTop MainActivity')
    main = mains[0]
    link_metadata = [item for item in main.findall('meta-data')
                     if item.get(ANDROID + 'name') == 'flutter_deeplinking_enabled']
    if len(link_metadata) != 1 or link_metadata[0].get(ANDROID + 'value') != 'false':
        raise ValueError('Subscription URLs must bypass Flutter automatic route handling')
    filters = [item for item in main.findall('intent-filter')
               if any(data.get(ANDROID + 'scheme') == 'pushokflow' for data in item.findall('data'))]
    if len(filters) != 1:
        raise ValueError('Subscription link intent filter missing or duplicated')
    link_filter = filters[0]
    if [item.get(ANDROID + 'name') for item in link_filter.findall('action')] != ['android.intent.action.VIEW'] or \
            sorted(item.get(ANDROID + 'name') for item in link_filter.findall('category')) != \
            ['android.intent.category.BROWSABLE', 'android.intent.category.DEFAULT'] or \
            len(link_filter.findall('data')) != 1 or link_filter.find('data').attrib != {
                ANDROID + 'scheme': 'pushokflow', ANDROID + 'host': 'subscription'}:
        raise ValueError('Subscription link intent filter must accept only its owned scheme and host')
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
    if not {'android.permission.REQUEST_INSTALL_PACKAGES',
            'android.permission.UPDATE_PACKAGES_WITHOUT_USER_ACTION',
            'android.permission.ACCESS_NETWORK_STATE'} <= permissions:
        raise ValueError('Background update installation or network permission missing')
    foreground = [item for item in app.findall('service')
                  if item.get(ANDROID + 'name') == UPDATE_FOREGROUND_SERVICE]
    if len(foreground) != 1 or foreground[0].get(ANDROID + 'exported') != 'false' or \
            foreground[0].get(ANDROID + 'foregroundServiceType') != 'dataSync' or \
            foreground[0].get(ANDROID + 'process') not in (None, 'shop.pushok.flow') or not {
                'android.permission.FOREGROUND_SERVICE', 'android.permission.FOREGROUND_SERVICE_DATA_SYNC',
                'android.permission.POST_NOTIFICATIONS'} <= permissions:
        raise ValueError('Update foreground download service must be private, dataSync and correctly permitted')
    for name, expected_action in ((UPDATE_INSTALL_RECEIVER, None),
                                   (UPDATE_REPLACED_RECEIVER, 'android.intent.action.MY_PACKAGE_REPLACED')):
        receivers = [item for item in app.findall('receiver')
                     if activity_name(item.get(ANDROID + 'name', '')) == name]
        if len(receivers) != 1 or receivers[0].get(ANDROID + 'exported') != 'false' or \
                receivers[0].get(ANDROID + 'process') not in (None, 'shop.pushok.flow'):
            raise ValueError('Update receivers must be single, private and in the default process')
        filters = receivers[0].findall('intent-filter')
        if expected_action is None:
            if filters:
                raise ValueError('Update installer callback must not expose an intent filter')
        elif len(filters) != 1 or len(list(filters[0])) != 1 or \
                filters[0][0].tag != 'action' or \
                filters[0][0].get(ANDROID + 'name') != expected_action:
            raise ValueError('Update replacement receiver must accept only MY_PACKAGE_REPLACED')
    providers = [item for item in app.findall('provider')
                 if activity_name(item.get(ANDROID + 'name', '')) == UPDATE_PROVIDER]
    if len(providers) != 1 or providers[0].get(ANDROID + 'exported') != 'false' or \
            providers[0].get(ANDROID + 'grantUriPermissions') != 'true' or \
            providers[0].get(ANDROID + 'authorities') != '${applicationId}.updates':
        raise ValueError('Update FileProvider must be private and scoped to the application')
    paths = providers[0].findall('meta-data')
    if sum(item.get(ANDROID + 'name') == 'android.support.FILE_PROVIDER_PATHS' and
           item.get(ANDROID + 'resource') == '@xml/update_paths' for item in paths) != 1:
        raise ValueError('Update FileProvider must use the restricted update paths')
    xray = [item for item in app.findall('service')
            if activity_name(item.get(ANDROID + 'name', '')) == XRAY_SERVICE]
    if xray:
        raise ValueError("WireGuard distribution contains an unexpected Xray service")
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
