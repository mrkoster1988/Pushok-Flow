#!/usr/bin/env python3
"""Restore a tracked public release delta; no private signing material is used."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import sys
import zipfile
import zlib

from restore_signed_apk import restore_bytes

REPOSITORY = 'mrkoster1988/Pushok-Flow'
PACKAGE = 'shop.pushok.flow'
CERTIFICATE = '8b4114881116a920c3351b503052ac27078fdbbfcae1ace27f1af8245ebb7047'
RELEASE_ROOT = f'https://github.com/{REPOSITORY}/releases'
MANIFEST_URL = RELEASE_ROOT + '/latest/download/update.json'
MAX_APK_BYTES = 200 * 1024 * 1024
MAX_ARTIFACT_BYTES = MAX_APK_BYTES + 1024 * 1024
MAX_STAGING_BYTES = 500 * 1024
MAX_LITERAL_BYTES = 500 * 1024
VERSION = re.compile(r'(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)')
SHA256 = re.compile(r'[0-9a-f]{64}')
SHA1 = re.compile(r'[0-9a-f]{40}')
ABIS = ('arm64-v8a', 'armeabi-v7a', 'x86_64')


def require(condition, message):
    if not condition:
        raise ValueError(message)


def integer(value, low, high):
    return type(value) is int and low <= value <= high


def fields(value, names, label):
    require(type(value) is dict and set(value) == set(names.split()), 'Invalid ' + label + ' fields')


def sha(value):
    return isinstance(value, str) and SHA256.fullmatch(value) is not None


def version(value):
    return isinstance(value, str) and len(value) <= 32 and VERSION.fullmatch(value) is not None


def manifest(release):
    return {'schemaVersion': 1, 'packageName': PACKAGE,
            'versionName': release['versionName'], 'versionCode': release['versionCode'],
            'minSdk': 24, 'apkUrl': RELEASE_ROOT + '/download/' + release['tag'] + '/' + release['apkName'],
            'sha256': release['sha256'], 'sizeBytes': release['sizeBytes'],
            'certificateSha256': CERTIFICATE}


def apk_name(version_name, abi=None, candidate=False):
    require(version(version_name) and (abi is None or abi in ABIS), 'Unexpected APK variant')
    return 'Pushok-Flow-v' + version_name + ('-' + abi if abi else '') + ('-candidate' if candidate else '') + '.apk'


def verification_name(abi=None):
    require(abi is None or abi in ABIS, 'Unexpected verification variant')
    return 'verified-release' + ('-' + abi if abi else '') + '.json'


def validate_manifest(value, abi=None):
    fields(value, 'schemaVersion packageName versionName versionCode minSdk apkUrl sha256 sizeBytes certificateSha256', 'manifest')
    require(type(value['schemaVersion']) is int and value['schemaVersion'] == 1, 'Invalid manifest schema')
    require(value['packageName'] == PACKAGE and value['certificateSha256'] == CERTIFICATE, 'Unexpected manifest identity')
    require(version(value['versionName']) and integer(value['versionCode'], 1, 2_100_000_000), 'Invalid manifest version')
    require(type(value['minSdk']) is int and value['minSdk'] == 24, 'Unexpected minimum SDK')
    require(integer(value['sizeBytes'], 1, MAX_APK_BYTES) and sha(value['sha256']), 'Invalid manifest bytes')
    v = value['versionName']
    require(value['apkUrl'] == f'{RELEASE_ROOT}/download/v{v}/' + apk_name(v, abi), 'Unexpected APK URL')
    return value


def validate_release(release, expected_version=None, abi=None):
    fields(release, 'tag versionName versionCode packageName apkName certificateSha256 sizeBytes sha256 minSdk', 'release')
    v = release['versionName']
    require(version(v) and (expected_version is None or v == expected_version), 'Unexpected release version')
    require(release['tag'] == 'v' + v and release['apkName'] == apk_name(v, abi), 'Unexpected release names')
    validate_manifest({key: release[key] for key in ('packageName', 'versionName', 'versionCode', 'minSdk', 'sha256', 'sizeBytes', 'certificateSha256')} |
                      {'schemaVersion': 1, 'apkUrl': manifest(release)['apkUrl']}, abi)


def validate_delta(value):
    fields(value['candidate'], 'sizeBytes sha256', 'candidate')
    require(integer(value['candidate']['sizeBytes'], 1, MAX_APK_BYTES) and sha(value['candidate']['sha256']), 'Invalid candidate bytes')
    literals = value['literals']
    fields(literals, 'encoding sizeBytes sha256 data', 'literals')
    require(literals['encoding'] == 'zlib+base64' and integer(literals['sizeBytes'], 0, MAX_LITERAL_BYTES)
            and sha(literals['sha256']) and isinstance(literals['data'], str)
            and len(literals['data']) <= (MAX_LITERAL_BYTES + 2) * 4 // 3 + 4, 'Invalid literal metadata')
    operations = value['operations']
    require(type(operations) is list and 0 < len(operations) <= 1000, 'Invalid operation count')
    total = 0
    for operation in operations:
        require(type(operation) is list and len(operation) == 3, 'Invalid operation')
        kind, offset, length = operation
        require(kind in ('copy', 'insert'), 'Invalid operation kind')
        limit = value['candidate']['sizeBytes'] if kind == 'copy' else literals['sizeBytes']
        require(integer(offset, 0, limit) and integer(length, 1, limit) and offset + length <= limit, 'Invalid operation bounds')
        total += length
        require(total <= value['release']['sizeBytes'], 'Operations exceed release size')
    require(total == value['release']['sizeBytes'], 'Operations do not cover release size')


def validate_staging(value, expected_version=None):
    require(type(value) is dict and type(value.get('schemaVersion')) is int
            and value['schemaVersion'] in (1, 2), 'Invalid staging schema')
    names = 'schemaVersion repository sourceCommit sourceRunId sourceChecksRunId sourceArtifact candidate release previousManifest notes operations literals'
    fields(value, names + (' variants' if value['schemaVersion'] == 2 else ''), 'staging')
    require(value['repository'] == REPOSITORY, 'Unexpected repository')
    require(isinstance(value['sourceCommit'], str) and SHA1.fullmatch(value['sourceCommit']), 'Invalid source commit')
    require(all(integer(value[k], 1, 2**63-1) for k in ('sourceRunId', 'sourceChecksRunId')), 'Invalid workflow run IDs')
    release = value['release']
    validate_release(release, expected_version)
    v = release['versionName']
    previous = validate_manifest(value['previousManifest'])
    require(release['versionCode'] > previous['versionCode'], 'Release must increase the published versionCode')
    require(tuple(map(int, v.split('.'))) > tuple(map(int, previous['versionName'].split('.'))), 'Release version must increase')
    require(isinstance(value['notes'], str) and 1 <= len(value['notes']) <= 20000 and '\0' not in value['notes'], 'Invalid release notes')
    artifact = value['sourceArtifact']
    fields(artifact, 'id name zipSizeBytes zipSha256 entryName', 'artifact')
    require(integer(artifact['id'], 1, 2**63-1) and artifact['name'] == 'pushok-flow-release-candidate', 'Invalid artifact identity')
    require(integer(artifact['zipSizeBytes'], 1, MAX_ARTIFACT_BYTES) and sha(artifact['zipSha256']), 'Invalid artifact bytes')
    require(artifact['entryName'] == apk_name(v, candidate=True), 'Unexpected candidate entry')
    validate_delta(value)
    if value['schemaVersion'] == 2:
        require(release['versionCode'] >= 40, 'ABI variants require build 40 or later')
        fields(value['variants'], ' '.join(ABIS), 'variants')
        for abi in ABIS:
            variant = value['variants'][abi]
            fields(variant, 'entryName candidate release operations literals', 'variant')
            require(variant['entryName'] == apk_name(v, abi, candidate=True), 'Unexpected variant candidate entry')
            validate_release(variant['release'], v, abi)
            for field in ('tag', 'versionName', 'versionCode', 'packageName', 'certificateSha256', 'minSdk'):
                require(variant['release'][field] == release[field], 'Variant release identity differs: ' + field)
            validate_delta(variant)
    return value


def release_payloads(document):
    """Enumerate the universal APK and all strictly named ABI payloads."""
    yield None, document['sourceArtifact']['entryName'], document
    for abi in ABIS if document['schemaVersion'] == 2 else ():
        variant = document['variants'][abi]
        yield abi, variant['entryName'], variant


def public_asset_names(document):
    result = []
    for _, _, payload in release_payloads(document):
        name = payload['release']['apkName']
        result.extend((name, name + '.sha256'))
    return result + ['update.json']


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, 'Duplicate JSON key')
        result[key] = value
    return result


def read_json(path, limit=MAX_STAGING_BYTES):
    require(path.is_file() and path.stat().st_size <= limit, 'JSON file missing or too large')
    return json.loads(path.read_text(encoding='utf-8'), object_pairs_hook=_unique_object)


def read_staging(path, expected_version=None):
    return validate_staging(read_json(path), expected_version)


def candidate_bytes(archive_path, artifact, expected=None):
    require(archive_path.stat().st_size == artifact['zipSizeBytes'], 'Artifact ZIP size differs')
    with archive_path.open('rb') as stream:
        require(hashlib.file_digest(stream, 'sha256').hexdigest() == artifact['zipSha256'], 'Artifact ZIP SHA256 differs')
    with zipfile.ZipFile(archive_path) as archive:
        matches = [entry for entry in archive.infolist() if entry.filename == artifact['entryName']]
        require(len(matches) == 1 and 0 < matches[0].file_size <= MAX_APK_BYTES and not matches[0].flag_bits & 1, 'Invalid candidate archive entry')
        if expected:
            require(matches[0].file_size == expected['sizeBytes'], 'Candidate size differs')
        candidate = archive.read(matches[0])
    if expected:
        require(hashlib.sha256(candidate).hexdigest() == expected['sha256'], 'Candidate SHA256 differs')
    return candidate


def restore(staging_path, archive_path, output):
    document = read_staging(staging_path)
    candidate = candidate_bytes(archive_path, document['sourceArtifact'], document['candidate'])
    restored = restore_bytes(candidate, document)
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open('xb') as stream:
        stream.write(restored)
    print(f'Restored verified public APK: {len(restored)} bytes; SHA256 {document["release"]["sha256"]}')


def restore_all(staging_path, archive_path, output_dir):
    document = read_staging(staging_path)
    payloads = list(release_payloads(document))
    targets = [output_dir / payload['release']['apkName'] for _, _, payload in payloads]
    require(all(not target.exists() for target in targets), 'Refusing to overwrite a restored APK')
    output_dir.mkdir(parents=True, exist_ok=True)
    for (_, entry_name, payload), target in zip(payloads, targets):
        artifact = {**document['sourceArtifact'], 'entryName': entry_name}
        candidate = candidate_bytes(archive_path, artifact, payload['candidate'])
        restored = restore_bytes(candidate, payload)
        with target.open('xb') as stream:
            stream.write(restored)
        print(f'Restored verified public APK {target.name}: {len(restored)} bytes; SHA256 {payload["release"]["sha256"]}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--staging', type=Path, required=True)
    parser.add_argument('--candidate-zip', type=Path, required=True)
    output = parser.add_mutually_exclusive_group(required=True)
    output.add_argument('--output', type=Path)
    output.add_argument('--output-dir', type=Path)
    args = parser.parse_args()
    try:
        if args.output_dir is not None:
            restore_all(args.staging, args.candidate_zip, args.output_dir)
        else:
            restore(args.staging, args.candidate_zip, args.output)
    except (ValueError, OSError, KeyError, TypeError, zipfile.BadZipFile, zlib.error) as error:
        print(f'Public restoration failed: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
