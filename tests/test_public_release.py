"""A public release must preserve tested payloads and advance the signed channel."""
import copy
import hashlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'tools'))
import create_public_release_delta as create
import publish_public_release as publish
import restore_public_release as restore


def zipped(payload=b'unchanged application bytes', signature=b'temporary signer', extra=b''):
    output = io.BytesIO()
    with zipfile.ZipFile(output, 'w') as archive:
        info = zipfile.ZipInfo('classes.dex')
        info.compress_type = zipfile.ZIP_DEFLATED
        info.extra = extra
        archive.writestr(info, payload)
        archive.writestr('assets/keep.txt', b'unchanged resource')
        archive.writestr('META-INF/CERT.SF', signature)
    return output.getvalue()


def fixture():
    candidate = zipped()
    signed = zipped(signature=b'permanent public signature', extra=b'\x55\x54\x00\x00')
    operations, literals = create.make_delta(candidate, signed)
    release = {'tag': 'v0.27.0', 'versionName': '0.27.0', 'versionCode': 27,
        'packageName': restore.PACKAGE, 'apkName': 'Pushok-Flow-v0.27.0.apk',
        'certificateSha256': restore.CERTIFICATE, 'sizeBytes': len(signed),
        'sha256': hashlib.sha256(signed).hexdigest(), 'minSdk': 24}
    previous = restore.manifest({**release, 'tag': 'v0.24.0', 'versionName': '0.24.0',
        'versionCode': 24, 'apkName': 'Pushok-Flow-v0.24.0.apk'})
    document = {'schemaVersion': 1, 'repository': restore.REPOSITORY, 'sourceCommit': 'ab'*20,
        'sourceRunId': 101, 'sourceChecksRunId': 102,
        'sourceArtifact': {'id': 103, 'name': 'pushok-flow-release-candidate',
            'zipSizeBytes': 999, 'zipSha256': 'cd'*32, 'entryName': 'Pushok-Flow-v0.27.0-candidate.apk'},
        'candidate': {'sizeBytes': len(candidate), 'sha256': hashlib.sha256(candidate).hexdigest()},
        'release': release, 'previousManifest': previous, 'notes': 'Functional update; physical test pending.',
        'operations': operations, 'literals': literals}
    return document, candidate, signed


class PublicDeltaTests(unittest.TestCase):
    def test_round_trip_preserves_exact_signed_bytes_with_alignment_and_signer_changes(self):
        document, candidate, signed = fixture()
        restore.validate_staging(document, '0.27.0')
        self.assertEqual(restore.restore_bytes(candidate, document), signed)
        self.assertTrue(any(op[0] == 'copy' for op in document['operations']))

    def test_modified_code_resource_or_entry_set_is_not_a_signing_delta(self):
        candidate = zipped()
        with self.assertRaisesRegex(ValueError, 'payload'):
            create.make_delta(candidate, zipped(payload=b'changed code'))
        extra = io.BytesIO(candidate)
        with zipfile.ZipFile(extra, 'a') as archive:
            archive.writestr('assets/new-code.dat', b'new executable bytes')
        with self.assertRaisesRegex(ValueError, 'entry set'):
            create.make_delta(candidate, extra.getvalue())

    def test_duplicate_entries_and_oversized_literals_are_rejected(self):
        archive_bytes = io.BytesIO(zipped())
        with zipfile.ZipFile(archive_bytes, 'a') as archive:
            with self.assertWarns(UserWarning):
                archive.writestr('classes.dex', b'different duplicate')
        with self.assertRaisesRegex(ValueError, 'Duplicate'):
            create.zip_payloads(archive_bytes.getvalue())
        with self.assertRaisesRegex(ValueError, 'literal limit'):
            create.make_delta(zipped(), zipped(signature=b'x'*(restore.MAX_LITERAL_BYTES+1)))

    def test_staging_rejects_wrong_identity_downgrade_path_and_noninteger_values(self):
        original, _, _ = fixture()
        mutations = [
            lambda d: d.update(repository='other/project'),
            lambda d: d.update(sourceCommit='main'),
            lambda d: d.update(sourceRunId=True),
            lambda d: d['release'].update(certificateSha256='aa'*32),
            lambda d: d['release'].update(versionCode=24),
            lambda d: d['release'].update(versionCode=True),
            lambda d: d['release'].update(apkName='../../other.apk'),
            lambda d: d['sourceArtifact'].update(entryName='../file.apk'),
            lambda d: d['previousManifest'].update(apkUrl='https://other.invalid/file.apk'),
            lambda d: d['operations'][0].__setitem__(1, -1),
            lambda d: d['operations'][0].__setitem__(2, True),
            lambda d: d['literals'].update(sizeBytes=restore.MAX_LITERAL_BYTES+1),
            lambda d: d.update(unexpected='field'),
        ]
        for index, mutation in enumerate(mutations):
            with self.subTest(index=index):
                document = copy.deepcopy(original)
                mutation(document)
                with self.assertRaises(ValueError):
                    restore.validate_staging(document)
        with self.assertRaises(ValueError):
            restore.validate_staging(original, '../../wrong')

    def test_tampered_candidate_literals_and_output_checksum_are_rejected(self):
        document, candidate, _ = fixture()
        with self.assertRaises(ValueError):
            restore.restore_bytes(candidate+b'corruption', document)
        broken = copy.deepcopy(document)
        broken['literals']['data'] = 'not-base64!'
        with self.assertRaises(ValueError):
            restore.restore_bytes(candidate, broken)
        broken = copy.deepcopy(document)
        broken['release']['sha256'] = '00'*32
        with self.assertRaises(ValueError):
            restore.restore_bytes(candidate, broken)

    def test_archive_identity_and_no_overwrite(self):
        document, candidate, signed = fixture()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive_path = root/'candidate.zip'
            with zipfile.ZipFile(archive_path, 'w') as archive:
                archive.writestr(document['sourceArtifact']['entryName'], candidate)
            document['sourceArtifact'].update(zipSizeBytes=archive_path.stat().st_size,
                zipSha256=hashlib.sha256(archive_path.read_bytes()).hexdigest())
            staging = root/'staging.json'
            staging.write_text(json.dumps(document))
            output = root/'release.apk'
            restore.restore(staging, archive_path, output)
            self.assertEqual(output.read_bytes(), signed)
            with self.assertRaises(FileExistsError):
                restore.restore(staging, archive_path, output)
            archive_path.write_bytes(archive_path.read_bytes()+b'changed')
            with self.assertRaisesRegex(ValueError, 'ZIP size'):
                restore.restore(staging, archive_path, root/'other.apk')

    def test_duplicate_json_fields_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/'duplicate.json'
            path.write_text('{"schemaVersion": 1, "schemaVersion": 2}')
            with self.assertRaisesRegex(ValueError, 'Duplicate'):
                restore.read_json(path)


class PublicPublisherTests(unittest.TestCase):
    class Response(io.BytesIO):
        headers = {'Cache-Control': 'max-age=60', 'Age': '12'}

        def getcode(self):
            return 200

        def geturl(self):
            return 'https://release-assets.githubusercontent.com/github-production-release-asset/test/update.json?secret-signed-query=private'

    def test_public_observation_uses_exact_stable_url_and_excludes_signed_query(self):
        document, _, _ = fixture()
        expected = restore.manifest(document['release'])
        raw = (json.dumps(expected, indent=2)+'\n').encode()
        observation = {}
        with mock.patch.object(publish.urllib.request, 'urlopen', return_value=self.Response(raw)) as opened:
            actual, received = publish.public_manifest(observation)
        self.assertEqual(actual, expected)
        self.assertEqual(received, raw)
        request = opened.call_args.args[0]
        self.assertEqual(request.full_url, restore.MANIFEST_URL)
        self.assertFalse(any(key.lower() == 'authorization' for key in request.headers))
        self.assertEqual(observation['observedVersion'], '0.27.0')
        self.assertEqual(observation['sha256'], hashlib.sha256(raw).hexdigest())
        self.assertNotIn('secret-signed-query', json.dumps(observation))

    def test_public_check_records_stale_version_before_exact_current_success(self):
        document, _, _ = fixture()
        expected = (json.dumps(restore.manifest(document['release']), indent=2)+'\n').encode()
        stale = json.dumps(document['previousManifest']).encode()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root/'update.json').write_bytes(expected)
            with mock.patch.object(publish.urllib.request, 'urlopen', side_effect=[self.Response(stale), self.Response(expected)]) as opened, \
                 mock.patch.object(publish.time, 'sleep') as sleep, mock.patch('builtins.print'):
                publish.verify_public(document, root, root/'observed')
            observations = json.loads((root/'observed/public-update-observations.json').read_text())
            self.assertEqual(opened.call_count, 2)
            sleep.assert_called_once_with(5)
            self.assertEqual([x['observedVersion'] for x in observations['attempts']], ['0.24.0', '0.27.0'])
            self.assertEqual([x['matches'] for x in observations['attempts']], [False, True])
            self.assertEqual((root/'observed/public-update.json').read_bytes(), expected)

    def test_public_check_waits_past_eight_stale_responses_without_republishing(self):
        document, _, _ = fixture()
        expected = (json.dumps(restore.manifest(document['release']), indent=2)+'\n').encode()
        stale = json.dumps(document['previousManifest']).encode()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root/'update.json').write_bytes(expected)
            responses = [self.Response(stale) for _ in range(8)] + [self.Response(expected)]
            with mock.patch.object(publish.urllib.request, 'urlopen', side_effect=responses) as opened, \
                 mock.patch.object(publish.time, 'sleep') as sleep, mock.patch('builtins.print'), \
                 mock.patch.object(publish, 'api') as api:
                publish.verify_public(document, root, root/'observed')
            attempts = json.loads((root/'observed/public-update-observations.json').read_text())['attempts']
            self.assertEqual(opened.call_count, 9)
            self.assertEqual(sleep.call_count, 8)
            self.assertEqual([x['matches'] for x in attempts], [False]*8 + [True])
            self.assertEqual((root/'observed/public-update.json').read_bytes(), expected)
            api.assert_not_called()

    def test_public_check_still_fails_after_bounded_stale_responses(self):
        document, _, _ = fixture()
        expected = (json.dumps(restore.manifest(document['release']), indent=2)+'\n').encode()
        stale = json.dumps(document['previousManifest']).encode()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root/'update.json').write_bytes(expected)
            with mock.patch.object(publish.urllib.request, 'urlopen', side_effect=lambda *a, **k: self.Response(stale)) as opened, \
                 mock.patch.object(publish.time, 'sleep') as sleep, mock.patch('builtins.print'), \
                 mock.patch.object(publish, 'api') as api:
                with self.assertRaisesRegex(ValueError, 'not confirmed'):
                    publish.verify_public(document, root, root/'observed')
            attempts = json.loads((root/'observed/public-update-observations.json').read_text())['attempts']
            self.assertEqual(opened.call_count, 24)
            self.assertEqual(sleep.call_count, 23)
            self.assertFalse(any(x['matches'] for x in attempts))
            self.assertFalse((root/'observed/public-update.json').exists())
            api.assert_not_called()

    def test_public_check_stops_on_http_denial_and_records_safe_reason(self):
        document, _, _ = fixture()
        expected = (json.dumps(restore.manifest(document['release']), indent=2)+'\n').encode()
        failure = publish.urllib.error.HTTPError(restore.MANIFEST_URL, 403, 'private-untrusted-message', {}, None)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root/'update.json').write_bytes(expected)
            with mock.patch.object(publish.urllib.request, 'urlopen', side_effect=failure) as opened, \
                 mock.patch.object(publish.time, 'sleep') as sleep, mock.patch('builtins.print'), \
                 mock.patch.object(publish, 'api') as api:
                with self.assertRaisesRegex(ValueError, 'last HTTP=403'):
                    publish.verify_public(document, root, root/'observed')
            recorded = (root/'observed/public-update-observations.json').read_text()
            attempts = json.loads(recorded)['attempts']
            self.assertEqual(opened.call_count, 1)
            sleep.assert_not_called()
            self.assertEqual(len(attempts), 1)
            self.assertTrue(all(x['httpStatus'] == 403 and x['failure'] == 'HTTP_ERROR' for x in attempts))
            self.assertNotIn('private-untrusted-message', recorded)
            api.assert_not_called()

    def test_ci_and_artifact_must_match_exact_approved_commit(self):
        document, _, _ = fixture()
        workflow = '.github/workflows/android-candidate.yml'
        run = {'status': 'completed', 'conclusion': 'success', 'head_sha': document['sourceCommit'],
            'head_branch': 'main', 'event': 'push', 'path': workflow,
            'repository': {'full_name': restore.REPOSITORY}, 'head_repository': {'full_name': restore.REPOSITORY}}
        publish.validate_run(run, document, workflow)
        for change in ({'conclusion': 'failure'}, {'head_sha': 'cd'*20}, {'event': 'pull_request'}, {'path': 'untrusted.yml'}):
            with self.subTest(change=change), self.assertRaises(ValueError):
                publish.validate_run({**run, **change}, document, workflow)
        expected = document['sourceArtifact']
        artifact = {'id': expected['id'], 'name': expected['name'], 'expired': False,
            'size_in_bytes': expected['zipSizeBytes'], 'digest': 'sha256:'+expected['zipSha256'],
            'workflow_run': {'id': document['sourceRunId'], 'head_sha': document['sourceCommit']}}
        publish.validate_artifact(artifact, document)
        with self.assertRaises(ValueError):
            publish.validate_artifact({**artifact, 'workflow_run': {'id': 999, 'head_sha': document['sourceCommit']}}, document)

    def test_current_channel_and_existing_draft_stop_publication(self):
        document, _, _ = fixture()
        latest = {'draft': False, 'prerelease': False, 'tag_name': 'v0.24.0'}
        with mock.patch.object(publish, 'api', return_value=latest), \
             mock.patch.object(publish, 'public_manifest', return_value=(document['previousManifest'], b'')):
            publish.require_previous(document)
        with mock.patch.object(publish, 'api', return_value=latest), \
             mock.patch.object(publish, 'public_manifest', return_value=({**document['previousManifest'], 'sha256': '00'*32}, b'')):
            with self.assertRaisesRegex(ValueError, 'manifest changed'):
                publish.require_previous(document)
        with mock.patch.object(publish, 'api', side_effect=[None, None, [{'tag_name': 'v0.27.0', 'draft': True}]]):
            with self.assertRaisesRegex(ValueError, 'draft already exists'):
                publish.require_absent('v0.27.0')

    def test_uploaded_assets_require_exact_set_size_and_digest(self):
        document, _, signed = fixture()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            apk_name = document['release']['apkName']
            (root/apk_name).write_bytes(signed)
            (root/(apk_name+'.sha256')).write_text(document['release']['sha256']+'  '+apk_name+'\n')
            (root/'update.json').write_text(json.dumps(restore.manifest(document['release'])))
            assets = [{'name': p.name, 'state': 'uploaded', 'size': p.stat().st_size,
                'digest': 'sha256:'+hashlib.sha256(p.read_bytes()).hexdigest()} for p in root.iterdir()]
            publish.validate_assets({'assets': assets}, document, root)
            for broken in (assets[:2], assets+[assets[0]], [{**assets[0], 'digest': 'sha256:'+'00'*32}]+assets[1:]):
                with self.assertRaises(ValueError):
                    publish.validate_assets({'assets': broken}, document, root)

    def test_publish_uses_created_numeric_id_and_checks_before_mutation(self):
        document, _, _ = fixture()
        tag = {'object': {'type': 'commit', 'sha': document['sourceCommit']}}
        draft = {'id': 765, 'tag_name': 'v0.27.0', 'draft': True, 'prerelease': False,
            'upload_url': f'https://uploads.github.com/repos/{restore.REPOSITORY}/releases/765/assets{{?name,label}}'}
        final = {**draft, 'draft': False}
        with tempfile.TemporaryDirectory() as directory, \
             mock.patch.object(publish, 'verify_local_assets'), \
             mock.patch.object(publish, 'preflight'), \
             mock.patch.object(publish, 'validate_assets'), \
             mock.patch.object(publish, 'require_previous'), \
             mock.patch.object(publish, 'upload_asset', return_value={}) as upload, \
             mock.patch.object(publish, 'api', side_effect=[tag, draft, draft, tag, final]) as api:
            publish.publish(document, Path(directory), Path(directory))
            self.assertEqual(api.call_args_list[2].args, ('releases/765',))
            self.assertEqual(api.call_args_list[-1].args[:2], ('releases/765', 'PATCH'))
            self.assertTrue(all('/releases/765/assets?' in call.args[0] for call in upload.call_args_list))
        with mock.patch.object(publish, 'verify_local_assets', side_effect=ValueError('changed')), \
             mock.patch.object(publish, 'api') as api:
            with self.assertRaises(ValueError):
                publish.publish(document, Path('unused'), Path('unused'))
            api.assert_not_called()


if __name__ == '__main__':
    unittest.main()
