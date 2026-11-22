#!/usr/bin/env python3
"""Materialize the official, immutable-by-digest libXray AAR at build time only."""
from __future__ import annotations
import argparse
import hashlib
import io
from pathlib import Path
import struct
import tempfile
import urllib.request
import zipfile

VERSION = 'v26.11.9'
URL = f'https://github.com/XTLS/libXray/releases/download/{VERSION}/libxray-android.zip'
ZIP_SIZE = 52_573_017
ZIP_SHA256 = '1b1aa12124a7112af983a6cea74c77f27aadc6b650acf3c5a57019619ba9fa48'
AAR_SIZE = 53_228_649
AAR_SHA256 = '4ddb0608ffee6e642ab9cda056c37df0b420a6b1e2be7292de33a1a3f3ca7a9a'
ABIS = ('arm64-v8a', 'armeabi-v7a', 'x86', 'x86_64')


def verify_elf_16k(data: bytes) -> None:
    if len(data) < 64 or data[:4] != b'\x7fELF' or data[5] != 1 or data[4] not in (1, 2):
        raise ValueError('Invalid native ELF header')
    is64 = data[4] == 2
    phoff = struct.unpack_from('<Q' if is64 else '<I', data, 32 if is64 else 28)[0]
    entry, count = struct.unpack_from('<HH', data, 54 if is64 else 42)
    expected = 56 if is64 else 32
    if entry != expected or not 1 <= count <= 128 or phoff + entry * count > len(data):
        raise ValueError('Invalid native ELF program table')
    loads = 0
    for offset in range(phoff, phoff + entry * count, entry):
        values = struct.unpack_from('<IIQQQQQQ' if is64 else '<IIIIIIII', data, offset)
        if values[0] != 1:
            continue
        file_offset, address, alignment = (values[2], values[3], values[7]) if is64 else (values[1], values[2], values[7])
        if alignment < 16384 or alignment & (alignment - 1) or (address - file_offset) % 16384:
            raise ValueError('Native library does not support 16 KiB pages')
        loads += 1
    if not loads:
        raise ValueError('Native ELF has no load segments')


def verify_aar(data: bytes) -> None:
    if len(data) != AAR_SIZE or hashlib.sha256(data).hexdigest() != AAR_SHA256:
        raise ValueError('Pinned libXray AAR checksum or size mismatch')
    with zipfile.ZipFile(io.BytesIO(data)) as aar:
        for abi in ABIS:
            verify_elf_16k(aar.read(f'jni/{abi}/libgojni.so'))
        for name in ('classes.jar', 'AndroidManifest.xml', 'proguard.txt'):
            if not aar.read(name):
                raise ValueError('Incomplete libXray AAR')


def materialize(destination: Path, archive: Path | None = None) -> None:
    if destination.exists():
        verify_aar(destination.read_bytes())
        return
    if archive is None:
        request = urllib.request.Request(URL, headers={'User-Agent': 'Pushok-Flow-build/0.36'})
        with urllib.request.urlopen(request, timeout=90) as response:
            data = response.read(ZIP_SIZE + 1)
    else:
        data = archive.read_bytes()
    if len(data) != ZIP_SIZE or hashlib.sha256(data).hexdigest() != ZIP_SHA256:
        raise ValueError('Pinned official libXray ZIP checksum or size mismatch')
    with zipfile.ZipFile(io.BytesIO(data)) as bundle:
        # Read one known member; never extract paths from a downloaded archive.
        aar = bundle.read('libxray-android/libXray.aar')
    verify_aar(aar)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=destination.parent, suffix='.tmp', delete=False) as output:
        temporary = Path(output.name)
        try:
            output.write(aar)
            output.flush()
            temporary.replace(destination)
        finally:
            temporary.unlink(missing_ok=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--archive', type=Path)
    parser.add_argument('--output', type=Path, default=Path(__file__).resolve().parents[1] / f'android/app/libs/libXray-{VERSION}.aar')
    args = parser.parse_args()
    materialize(args.output, args.archive)
    print(f'Official libXray {VERSION}: ZIP/AAR SHA-256 and four ABI ELF 16 KiB alignment verified')
