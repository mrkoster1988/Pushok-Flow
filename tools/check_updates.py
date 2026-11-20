"""Offline validation primitives. Production updater MUST verify signatures."""
from __future__ import annotations
import hashlib
import re
from pathlib import Path

_VERSION = re.compile(r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$")


def version_tuple(version: str) -> tuple[int, int, int]:
    if not isinstance(version, str) or not _VERSION.fullmatch(version):
        raise ValueError("Expected MAJOR.MINOR.PATCH")
    return tuple(map(int, version.split(".")))


def is_update(current: str, offered: str) -> bool:
    return version_tuple(offered) > version_tuple(current)


def check_sha256(path: str | Path, expected_hex: str) -> bool:
    if not re.fullmatch(r"[0-9a-fA-F]{64}", expected_hex):
        raise ValueError("Invalid SHA-256 digest")
    h = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest() == expected_hex.lower()


def validate_rules_update(current: int, offered: int) -> bool:
    if isinstance(current, bool) or isinstance(offered, bool):
        raise ValueError("Rules version must be integer")
    if not isinstance(current, int) or not isinstance(offered, int) or current < 0 or offered < 0:
        raise ValueError("Rules version must be non-negative integer")
    return offered > current