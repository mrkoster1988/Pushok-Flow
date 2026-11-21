import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
import capture_dart_dependencies as snapshot


class DartDependencySnapshotTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / 'config').mkdir()
        (self.root / 'config/dependency-lock.json').write_text('{"flutter":"3.50.0"}')
        (self.root / 'pubspec.yaml').write_text('name: pushok_flow\n')
        self.lock = b'# An already resolved fixture, never used to build the app.\npackages: {}\n'
        (self.root / 'pubspec.lock').write_bytes(self.lock)
        self.output = self.root / 'snapshot'
        self.calls = []

    def tool(self, command, root):
        self.calls.append(command)
        if command == ['flutter', '--version', '--machine']:
            return {'frameworkVersion': '3.50.0'}
        if command == ['flutter', 'pub', 'deps', '--json']:
            return {'root': 'pushok_flow', 'packages': [{'name': 'pushok_flow', 'version': '0.25.0'}]}
        self.fail(f'Unexpected command which may modify the dependency resolution: {command}')

    def test_snapshot_preserves_exact_locked_inputs_and_verifiable_hashes(self):
        data = snapshot.capture(self.root, self.output, run_json=self.tool)
        self.assertEqual((self.output / 'pubspec.lock').read_bytes(), self.lock)
        self.assertEqual(data['filesSha256']['pubspec.lock'], hashlib.sha256(self.lock).hexdigest())
        for filename, digest in data['filesSha256'].items():
            self.assertEqual(hashlib.sha256((self.output / filename).read_bytes()).hexdigest(), digest)
        self.assertEqual(json.loads((self.output / 'pub-deps.json').read_text())['root'], 'pushok_flow')

    def test_missing_lock_fails_without_running_flutter_or_emitting_a_snapshot(self):
        (self.root / 'pubspec.lock').unlink()
        with self.assertRaises(FileNotFoundError):
            snapshot.capture(self.root, self.output, run_json=self.tool)
        self.assertFalse(self.calls)
        self.assertFalse(self.output.exists())

    def test_wrong_sdk_fails_without_emitting_a_snapshot(self):
        def wrong_sdk(command, root):
            value = self.tool(command, root)
            if '--machine' in command:
                value['frameworkVersion'] = '3.51.0'
            return value
        with self.assertRaisesRegex(ValueError, 'different Flutter SDK'):
            snapshot.capture(self.root, self.output, run_json=wrong_sdk)
        self.assertFalse(self.output.exists())

    def test_graph_for_another_project_is_rejected(self):
        def wrong_graph(command, root):
            value = self.tool(command, root)
            if 'deps' in command:
                value['root'] = 'another_app'
            return value
        with self.assertRaisesRegex(ValueError, 'does not belong'):
            snapshot.capture(self.root, self.output, run_json=wrong_graph)
        self.assertFalse(self.output.exists())

    def test_unexpected_lock_rewrite_is_not_attested(self):
        def rewriting_tool(command, root):
            value = self.tool(command, root)
            (root / 'pubspec.lock').write_text('packages: changed\n')
            return value
        with self.assertRaisesRegex(ValueError, 'changed while capturing'):
            snapshot.capture(self.root, self.output, run_json=rewriting_tool)
        self.assertFalse(self.output.exists())


if __name__ == '__main__':
    unittest.main()
