#!/usr/bin/env python3
"""Restore the approved public APK bytes; this tool never signs an APK."""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import sys
import zipfile
import zlib


MAX_STAGING_BYTES = 500 * 1024
MAX_LITERAL_BYTES = 500 * 1024
MAX_APK_BYTES = 200 * 1024 * 1024


def require(condition, message):
    if not condition:
        raise ValueError(message)


def integer(value, minimum, maximum):
    return type(value) is int and minimum <= value <= maximum


def digest(data):
    return hashlib.sha256(data).hexdigest()


def read_staging(path):
    require(path.stat().st_size <= MAX_STAGING_BYTES, 'Public delta is too large')
    document = json.loads(path.read_text(encoding='utf-8'))
    require(document['schemaVersion'] == 1, 'Unsupported delta schema')
    require(document['repository'] == 'mrkoster1988/Pushok-Flow', 'Unexpected repository')
    require(document['sourceCommit'] == '355813cbf74a8f69a9cdf4c83869faa9d7b46b13',
            'This recovery publisher supports only the approved v0.24.0 build')
    require(document['sourceRunId'] == 44825972948, 'Unexpected source run')
    require(document['sourceArtifact'] == {
        'id': 14674086637,
        'name': 'pushok-flow-release-candidate',
        'zipSizeBytes': 28007040,
        'zipSha256': 'db39baf79e391b5ebb71929346c41dbb7373c964faecb840a99a99bb33d4da6d',
        'entryName': 'Pushok-Flow-v0.24.0-candidate.apk',
    }, 'Unexpected source artifact')
    require(document['candidate'] == {
        'sizeBytes': 60323003,
        'sha256': '2e0da85ec0de11bfbb7e97afd42274d419dcdcc7889190c55c3a813642c23e73',
    }, 'Unexpected candidate identity')
    require(document['release'] == {
        'tag': 'v0.24.0', 'versionName': '0.24.0', 'versionCode': 24,
        'packageName': 'shop.pushok.flow', 'apkName': 'Pushok-Flow-v0.24.0.apk',
        'certificateSha256': '8b4114881116a920c3351b503052ac27078fdbbfcae1ace27f1af8245ebb7047',
        'sizeBytes': 60332830,
        'sha256': 'fb7c45e7bfdf2fb804a3b92cc2f4d7acb9af9173aa093307cbad975fdcf6f228',
    }, 'Unexpected approved release identity')
    require(isinstance(document['operations'], list) and 0 < len(document['operations']) <= 1000,
            'Invalid delta operations')
    return document


def restore_bytes(candidate, document):
    expected = document['candidate']
    require(len(candidate) == expected['sizeBytes'] and digest(candidate) == expected['sha256'],
            'Candidate APK bytes do not match the approved CI build')
    literals = document['literals']
    require(literals['encoding'] == 'zlib+base64', 'Unsupported literal encoding')
    require(integer(literals['sizeBytes'], 0, MAX_LITERAL_BYTES), 'Invalid literal size')
    compressed = base64.b64decode(literals['data'], validate=True)
    require(len(compressed) <= MAX_LITERAL_BYTES, 'Compressed literals are too large')
    decoder = zlib.decompressobj()
    literal_data = decoder.decompress(compressed, literals['sizeBytes'] + 1)
    require(decoder.eof and not decoder.unused_data and not decoder.unconsumed_tail
            and len(literal_data) == literals['sizeBytes'], 'Invalid or oversized literal stream')
    require(digest(literal_data) == literals['sha256'], 'Literal SHA256 differs')
    total = 0
    blocks = []
    for operation in document['operations']:
        require(isinstance(operation, list) and len(operation) == 3, 'Invalid delta operation')
        kind, offset, length = operation
        require(kind in ('copy', 'insert'), 'Unknown delta operation')
        source = candidate if kind == 'copy' else literal_data
        require(integer(offset, 0, len(source)) and integer(length, 1, len(source))
                and offset + length <= len(source), 'Delta range is outside its source')
        total += length
        require(total <= document['release']['sizeBytes'] <= MAX_APK_BYTES,
                'Reconstructed APK exceeds the approved size')
        blocks.append(source[offset:offset + length])
    result = b''.join(blocks)
    require(len(result) == document['release']['sizeBytes']
            and digest(result) == document['release']['sha256'],
            'Reconstructed APK differs from the already signed and verified APK')
    return result


def restore(staging_path, archive_path, output):
    document = read_staging(staging_path)
    artifact = document['sourceArtifact']
    require(archive_path.stat().st_size == artifact['zipSizeBytes'], 'Artifact ZIP size differs')
    with archive_path.open('rb') as stream:
        archive_digest = hashlib.file_digest(stream, 'sha256').hexdigest()
    require(archive_digest == artifact['zipSha256'], 'Artifact ZIP SHA256 differs')
    with zipfile.ZipFile(archive_path) as archive:
        entries = [entry for entry in archive.infolist() if entry.filename == artifact['entryName']]
        require(len(entries) == 1 and entries[0].file_size == document['candidate']['sizeBytes'],
                'Artifact does not contain the exact candidate APK')
        candidate = archive.read(entries[0])
    restored = restore_bytes(candidate, document)
    output.parent.mkdir(parents=True, exist_ok=True)
    # Never replace a local result that could already have been reviewed.
    with output.open('xb') as stream:
        stream.write(restored)
    print(f"Restored {len(restored)} approved public APK bytes; SHA256 {digest(restored)}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--staging', type=Path, required=True)
    parser.add_argument('--candidate-zip', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    try:
        restore(args.staging, args.candidate_zip, args.output)
    except (ValueError, OSError, KeyError, TypeError, zipfile.BadZipFile, zlib.error) as error:
        print(f'Public APK restoration failed: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
