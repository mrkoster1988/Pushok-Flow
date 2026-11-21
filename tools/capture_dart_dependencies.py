#!/usr/bin/env python3
"""Preserve the resolved Dart inputs of a checked CI build, without resolving them."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess


def command_json(command: list[str], root: Path) -> dict:
    result = subprocess.run(command, cwd=root, capture_output=True, text=True,
                            check=True, timeout=120)
    data = json.loads(result.stdout)
    if not isinstance(data, dict):
        raise ValueError('Expected an object from the Flutter dependency command')
    return data


def capture(root: Path, output: Path, *, run_json=command_json) -> dict:
    # Read all required files before producing an artifact. A missing lock is
    # an error, never a reason to resolve or upgrade dependencies here.
    inputs = {name: (root / name).read_bytes()
              for name in ('pubspec.yaml', 'pubspec.lock')}
    if not inputs['pubspec.lock'].strip():
        raise ValueError('The Dart dependency lockfile is empty')
    expected_flutter = json.loads((root / 'config/dependency-lock.json').read_text())['flutter']
    graph = run_json(['flutter', 'pub', 'deps', '--json'], root)
    toolchain = run_json(['flutter', '--version', '--machine'], root)
    if toolchain.get('frameworkVersion') != expected_flutter:
        raise ValueError('Dependency snapshot uses a different Flutter SDK from the pinned baseline')
    name = re.search(rb'(?m)^name:\s*([a-z0-9_]+)\s*$', inputs['pubspec.yaml'])
    if not name or graph.get('root') != name.group(1).decode():
        raise ValueError('Dependency graph does not belong to this application')
    packages = graph.get('packages')
    if not isinstance(packages, list) or not packages:
        raise ValueError('Resolved dependency graph is missing packages')
    # The graph must describe the same inputs that are preserved. These commands
    # are read-only; fail if a tool unexpectedly rewrites either input.
    for filename, original in inputs.items():
        if (root / filename).read_bytes() != original:
            raise ValueError('Dependency inputs changed while capturing their graph')
    payloads = {
        **inputs,
        'pub-deps.json': (json.dumps(graph, indent=2) + '\n').encode(),
        'flutter-version.json': (json.dumps(toolchain, indent=2) + '\n').encode(),
    }
    metadata = {
        'kind': 'resolved-dart-dependencies',
        'sourceCommit': os.environ.get('GITHUB_SHA'),
        'workflowRunId': os.environ.get('GITHUB_RUN_ID'),
        'flutterVersion': expected_flutter,
        'packageCount': len(packages),
        'filesSha256': {name: hashlib.sha256(data).hexdigest()
                        for name, data in sorted(payloads.items())},
        'scope': 'Dart and Flutter dependency inputs only; not a complete native dependency or security audit.',
    }
    output.mkdir(parents=True, exist_ok=True)
    for filename, data in payloads.items():
        (output / filename).write_bytes(data)
    (output / 'provenance.json').write_text(json.dumps(metadata, indent=2) + '\n')
    return metadata


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    metadata = capture(root, args.output.resolve())
    print(f"Preserved {metadata['packageCount']} resolved Dart packages with exact input hashes.")


if __name__ == '__main__':
    main()
