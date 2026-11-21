#!/usr/bin/env python3
"""Create a bounded public APK delta after local signing and verification."""
import argparse
import base64
import hashlib
import io
import json
from pathlib import Path
import re
import struct
import sys
import zipfile
import zlib

from create_update_manifest import build_manifest
from restore_public_release import (REPOSITORY, MAX_APK_BYTES, MAX_LITERAL_BYTES,
    MAX_STAGING_BYTES, candidate_bytes, read_json, require, restore_bytes, validate_staging)

SIGNATURE = re.compile(r'META-INF/(?:MANIFEST\.MF|[^/]+\.(?:SF|RSA|DSA|EC))', re.IGNORECASE)


def zip_payloads(data):
    """Return compressed payload ranges; never decompress APK entries."""
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        entries = archive.infolist()
        require(len(entries) <= 10000 and len({x.filename for x in entries}) == len(entries), 'Duplicate or excessive APK entries')
        result = {}
        for entry in entries:
            require(not entry.flag_bits & 1 and entry.compress_type in (0, 8), 'Unsupported APK ZIP entry')
            offset = entry.header_offset
            require(offset >= 0 and offset + 30 <= len(data), 'Invalid APK ZIP header')
            header = struct.unpack_from('<IHHHHHIIIHH', data, offset)
            require(header[0] == 0x04034B50 and header[3] == entry.compress_type, 'Invalid APK local header')
            start = offset + 30 + header[-2] + header[-1]
            require(start + entry.compress_size <= len(data), 'Invalid APK payload bounds')
            result[entry.filename] = (start, entry.compress_size, entry.file_size, entry.CRC, entry.compress_type)
    return result


def make_delta(candidate, signed):
    old = zip_payloads(candidate)
    new = zip_payloads(signed)
    payload_names = lambda entries: {name for name in entries if not SIGNATURE.fullmatch(name)}
    require(payload_names(old) == payload_names(new), 'Signing changed the APK payload entry set')
    for name in payload_names(old):
        before, after = old[name], new[name]
        require(before[1:] == after[1:] and candidate[before[0]:before[0]+before[1]] == signed[after[0]:after[0]+after[1]],
                'Signing changed an APK payload')
    literals = bytearray()
    operations = []
    cursor = 0

    def insert(block):
        if block:
            require(len(literals) + len(block) <= MAX_LITERAL_BYTES, 'Public signature delta exceeds the literal limit')
            operations.append(['insert', len(literals), len(block)])
            literals.extend(block)

    for name, after in sorted(new.items(), key=lambda pair: pair[1][0]):
        before = old.get(name)
        if after[1] == 0 or before is None or before[1:] != after[1:]:
            continue
        if candidate[before[0]:before[0]+before[1]] != signed[after[0]:after[0]+after[1]]:
            continue
        require(after[0] >= cursor, 'Overlapping APK payloads')
        insert(signed[cursor:after[0]])
        operations.append(['copy', before[0], before[1]])
        cursor = after[0] + after[1]
    insert(signed[cursor:])
    raw = bytes(literals)
    return operations, {'encoding': 'zlib+base64', 'sizeBytes': len(raw),
        'sha256': hashlib.sha256(raw).hexdigest(),
        'data': base64.b64encode(zlib.compress(raw, 9)).decode('ascii')}


def create(args):
    verified = read_json(args.verified)
    update = build_manifest(args.signed_apk, verified, args.pubspec)
    v = update['versionName']
    artifact = {'id': args.artifact_id, 'name': 'pushok-flow-release-candidate',
        'zipSizeBytes': args.artifact_size, 'zipSha256': args.artifact_sha256,
        'entryName': f'Pushok-Flow-v{v}-candidate.apk'}
    candidate = candidate_bytes(args.candidate_zip, artifact)
    require(args.signed_apk.stat().st_size <= MAX_APK_BYTES, 'Signed APK too large')
    signed = args.signed_apk.read_bytes()
    operations, literals = make_delta(candidate, signed)
    release = {key: update[key] for key in ('packageName', 'versionName', 'versionCode', 'minSdk', 'sha256', 'sizeBytes', 'certificateSha256')}
    release.update(tag='v'+v, apkName=f'Pushok-Flow-v{v}.apk')
    document = {'schemaVersion': 1, 'repository': REPOSITORY,
        'sourceCommit': args.source_commit, 'sourceRunId': args.source_run_id,
        'sourceChecksRunId': args.checks_run_id, 'sourceArtifact': artifact,
        'candidate': {'sizeBytes': len(candidate), 'sha256': hashlib.sha256(candidate).hexdigest()},
        'release': release, 'previousManifest': read_json(args.previous_manifest, 65536),
        'notes': args.notes.read_text(encoding='utf-8'), 'operations': operations, 'literals': literals}
    validate_staging(document, v)
    require(restore_bytes(candidate, document) == signed, 'Local delta round-trip differs')
    encoded = (json.dumps(document, ensure_ascii=False, indent=2) + '\n').encode('utf-8')
    require(len(encoded) <= MAX_STAGING_BYTES, 'Staging JSON too large')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open('xb') as stream:
        stream.write(encoded)
    print(f'Created public v{v} delta: {len(operations)} operations, {len(encoded)} JSON bytes; no private signing material read')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('candidate-zip', 'signed-apk', 'verified', 'pubspec', 'previous-manifest', 'notes', 'output'):
        parser.add_argument('--'+name, type=Path, required=True)
    for name in ('source-run-id', 'checks-run-id', 'artifact-id', 'artifact-size'):
        parser.add_argument('--'+name, type=int, required=True)
    for name in ('source-commit', 'artifact-sha256'):
        parser.add_argument('--'+name, required=True)
    try:
        create(parser.parse_args())
    except (ValueError, OSError, KeyError, TypeError, zipfile.BadZipFile, zlib.error) as error:
        print(f'Public delta creation failed: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
