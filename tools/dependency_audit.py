#!/usr/bin/env python3
"""Read-only update audit. No dependency or installation is changed.

Checks Maven metadata for WireGuard and Flutter stable release via GitHub.
Run `python tools/dependency_audit.py --output dependency-report.md`.
"""
from __future__ import annotations
import argparse
import json
import re
import sys
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MAVEN = 'https://repo.maven.apache.org/maven2/com/wireguard/android/tunnel/maven-metadata.xml'
FLUTTER = 'https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json'


def get(url: str) -> bytes:
    req = urllib.request.Request(url, headers={'User-Agent': 'Pushok-Flow-dependency-audit/0.4', 'Accept': 'application/vnd.github+json'})
    with urllib.request.urlopen(req, timeout=20) as response:
        return response.read(1024 * 1024)


def parse_wireguard(xml: bytes) -> str:
    node = ET.fromstring(xml).find('./versioning/release')
    if node is None or not node.text or not re.fullmatch(r'1\.0\.\d{8}', node.text):
        raise ValueError('Unexpected WireGuard Maven version')
    return node.text


def parse_flutter(data: bytes) -> str:
    payload = json.loads(data)
    stable_hash = payload['current_release']['stable']
    tag = next(release['version'] for release in payload['releases'] if release['hash'] == stable_hash)
    if not re.fullmatch(r'\d+\.\d+\.\d+', tag):
        raise ValueError('GitHub latest release is not a stable Flutter tag')
    return tag


def version_order(value: str) -> tuple[int, ...]:
    return tuple(int(part) for part in value.replace('1.0.', '1.0.').split('.'))


def audit(fetch=get) -> tuple[str, bool, bool]:
    pinned = json.loads((ROOT / 'config/dependency-lock.json').read_text(encoding='utf-8'))
    checks = [('WireGuard Android tunnel', 'wireguard_android_tunnel', MAVEN, parse_wireguard),
              ('Flutter stable', 'flutter', FLUTTER, parse_flutter)]
    lines = ['# Pushok Flow — аудит обновлений', '', 'Проверка выполняется без установки обновлений.', '', '| Зависимость | Зафиксировано | Доступно | Результат |', '|---|---|---|---|']
    outdated = False
    failed = False
    for title, key, url, parser in checks:
        current = pinned[key]
        try:
            available = parser(fetch(url))
            needs_update = version_order(available) > version_order(current)
            status = 'Есть новая версия; нужна проверка' if needs_update else 'Актуально или версия новее'
            outdated |= needs_update
        except (OSError, ValueError, KeyError, ET.ParseError, json.JSONDecodeError) as exc:
            available = '—'
            status = f'Не удалось проверить: {type(exc).__name__}'
            failed = True
        lines.append(f'| {title} | `{current}` | `{available}` | {status} |')
    lines += ['', '## Правило безопасности', '', '- Никогда не обновлять VPN-движок без успешной сборки и проверок трафика на устройстве.', '- Любые изменения WireGuard, маршрутов, DNS или IPv6 требуют ручного одобрения.', '- Это аудит, не автоматический установщик.', '']
    return '\n'.join(lines), outdated, failed


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', default='dependency-report.md')
    args = parser.parse_args()
    report, outdated, failed = audit()
    Path(args.output).write_text(report, encoding='utf-8')
    print(report)
    if failed:
        return 2
    return 0


if __name__ == '__main__':
    sys.exit(main())