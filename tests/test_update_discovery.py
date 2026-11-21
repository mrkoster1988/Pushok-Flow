"""Public discovery must select a stable release and verify its exact manifest."""
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
import urllib.error
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
import publish_public_release as publish
from test_public_release import fixture
from restore_public_release import manifest


class Response(io.BytesIO):
    headers = {'Age': '0'}

    def getcode(self):
        return 200

    def geturl(self):
        return 'https://release-assets.githubusercontent.com/github-production-release-asset/update.json?signature=hidden'


class UpdateDiscoveryTests(unittest.TestCase):
    def test_release_discovery_has_no_credentials_and_requests_revalidation(self):
        data = {'id': 123, 'tag_name': 'v0.31.0', 'draft': False, 'prerelease': False,
                'published_at': '2026-11-21T22:00:00Z'}
        opener = mock.Mock()
        opener.open.return_value = Response(json.dumps(data).encode())
        observation = {}
        with mock.patch.dict(os.environ, {'GH_TOKEN': 'NEVER_SEND_THIS'}), \
                mock.patch.object(publish.urllib.request, 'build_opener', return_value=opener):
            self.assertEqual(publish.public_latest_release(observation), 'v0.31.0')
        request = opener.open.call_args.args[0]
        self.assertEqual(request.full_url, publish.API_ROOT + 'releases/latest')
        headers = {key.lower(): value for key, value in request.header_items()}
        self.assertNotIn('authorization', headers)
        self.assertNotIn('cookie', headers)
        self.assertEqual(headers['cache-control'], 'no-cache, max-age=0')
        self.assertEqual(headers['pragma'], 'no-cache')
        self.assertEqual(observation['observedTag'], 'v0.31.0')

    def test_invalid_draft_prerelease_unpublished_or_oversized_responses_fail(self):
        good = {'id': 123, 'tag_name': 'v0.31.0', 'draft': False, 'prerelease': False,
                'published_at': '2026-11-21T22:00:00Z'}
        payloads = [json.dumps({**good, **change}).encode() for change in (
            {'draft': True}, {'prerelease': True}, {'published_at': None},
            {'tag_name': 'v../other'}, {'tag_name': 'v0.31.0-beta'}, {'draft': 0},
            {'id': True}, {'id': 0}, {'id': None}, {'published_at': 'invalid'})]
        payloads.extend([b'[]', b'x' * (256 * 1024 + 1)])
        for raw in payloads:
            with self.subTest(raw=raw[:80]):
                opener = mock.Mock()
                opener.open.return_value = Response(raw)
                with mock.patch.object(publish.urllib.request, 'build_opener', return_value=opener):
                    with self.assertRaises(ValueError):
                        publish.public_latest_release({})

    def test_selected_release_fetches_only_its_pinned_manifest(self):
        document, _, _ = fixture()
        expected = manifest(document['release'])
        raw = json.dumps(expected).encode()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'update.json').write_bytes(raw)
            with mock.patch.object(publish, 'public_latest_release', return_value='v0.27.0'), \
                    mock.patch.object(publish, 'public_manifest', return_value=(expected, raw)) as fetch:
                publish.verify_discovery(document, root, root / 'diagnostics')
            self.assertEqual(fetch.call_args.kwargs['request_url'],
                f'https://github.com/{publish.REPOSITORY}/releases/download/v0.27.0/update.json')
            report = json.loads((root / 'diagnostics/update-discovery-observations.json').read_text())
            self.assertTrue(report['attempts'][0]['matches'])

    def test_stale_release_is_not_accepted_even_with_age_zero(self):
        document, _, _ = fixture()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'update.json').write_text(json.dumps(manifest(document['release'])))
            with mock.patch.object(publish, 'public_latest_release', return_value='v0.24.0'), \
                    mock.patch.object(publish, 'public_manifest') as fetch, \
                    mock.patch.object(publish.time, 'sleep'):
                with self.assertRaisesRegex(ValueError, 'not confirmed'):
                    publish.verify_discovery(document, root, root / 'diagnostics')
            fetch.assert_not_called()
            report = json.loads((root / 'diagnostics/update-discovery-observations.json').read_text())
            self.assertEqual(len(report['attempts']), 4)
            self.assertFalse(any(item['matches'] for item in report['attempts']))

    def test_old_or_changed_manifest_cannot_confirm_the_selected_release(self):
        document, _, _ = fixture()
        expected = manifest(document['release'])
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'update.json').write_text(json.dumps(expected))
            old = document['previousManifest']
            with mock.patch.object(publish, 'public_latest_release', return_value='v0.27.0'), \
                    mock.patch.object(publish, 'public_manifest', return_value=(old, json.dumps(old).encode())), \
                    mock.patch.object(publish.time, 'sleep'):
                with self.assertRaisesRegex(ValueError, 'not confirmed'):
                    publish.verify_discovery(document, root, root / 'diagnostics')

    def test_public_manifest_rejects_unexpected_paths_before_network(self):
        invalid = ['https://evil.invalid/update.json',
            f'https://github.com/{publish.REPOSITORY}/releases/download/v0.31.0/update.json?anything=1',
            f'https://github.com/{publish.REPOSITORY}/releases/download/v../other/update.json']
        with mock.patch.object(publish.urllib.request, 'urlopen') as fetch:
            for url in invalid:
                with self.assertRaisesRegex(ValueError, 'Unexpected'):
                    publish.public_manifest(request_url=url)
            fetch.assert_not_called()

    def test_non_200_success_codes_do_not_pass_the_updater_check(self):
        response = Response(b'{}')
        response.getcode = lambda: 206
        opener = mock.Mock()
        opener.open.return_value = response
        with mock.patch.object(publish.urllib.request, 'build_opener', return_value=opener):
            with self.assertRaisesRegex(ValueError, 'HTTP 200'):
                publish.public_latest_release({})
        response = Response(b'{}')
        response.getcode = lambda: 202
        with mock.patch.object(publish.urllib.request, 'urlopen', return_value=response):
            with self.assertRaisesRegex(ValueError, 'HTTP 200'):
                publish.public_manifest({})

    def test_rate_limited_discovery_is_recorded_without_an_immediate_retry(self):
        document, _, _ = fixture()
        opener = mock.Mock()
        opener.open.side_effect = urllib.error.HTTPError(
            publish.API_ROOT + 'releases/latest', 429, 'Too many requests',
            {'Retry-After': '60', 'X-RateLimit-Reset': '1800000000'}, None)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'update.json').write_text(json.dumps(manifest(document['release'])))
            with mock.patch.object(publish.urllib.request, 'build_opener', return_value=opener), \
                    mock.patch.object(publish.time, 'sleep') as sleep:
                with self.assertRaisesRegex(ValueError, 'rate-limited'):
                    publish.verify_discovery(document, root, root / 'diagnostics')
                sleep.assert_not_called()
            self.assertEqual(opener.open.call_count, 1)
            report = json.loads((root / 'diagnostics/update-discovery-observations.json').read_text())
            self.assertEqual(report['attempts'][0]['release']['retryAfter'], '60')


if __name__ == '__main__':
    unittest.main()
