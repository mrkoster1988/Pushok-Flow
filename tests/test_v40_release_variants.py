"""ABI releases keep the legacy manifest and prove every signed/public payload."""
import copy
import hashlib
import io
import json
import os
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
import urllib.error
from unittest import mock
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
import create_public_release_delta as create
import create_update_manifest as updates
import publish_public_release as publish
import restore_public_release as restore
from test_public_release import fixture as legacy_fixture, release_metadata, zipped


class Response(io.BytesIO):
    def __init__(self, data, status=200, declared=None):
        super().__init__(data)
        self.status = status
        self.headers = {'Content-Length': str(len(data) if declared is None else declared)}

    def getcode(self):
        return self.status

    def geturl(self):
        return 'https://release-assets.githubusercontent.com/github-production-release-asset/check?signature=DO_NOT_LOG'


class VariantReleaseTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.dist = self.root / 'dist'
        self.dist.mkdir()
        self.pubspec = self.root / 'pubspec.yaml'
        self.pubspec.write_text('name: pushok_flow\nversion: 0.40.0+40\n')
        self.candidates = {}
        self.signed = {}
        self.reports = {}
        for abi in (None, *restore.ABIS):
            content = ('unchanged code for ' + str(abi)).encode()
            self.candidates[abi] = zipped(payload=content)
            self.signed[abi] = zipped(payload=content, signature=b'permanent release signature')
            name = restore.apk_name('0.40.0', abi)
            (self.dist / name).write_bytes(self.signed[abi])
            report = {'packageName': restore.PACKAGE, 'versionName': '0.40.0',
                'versionCode': 40, 'minSdk': 24, 'certificateSha256': restore.CERTIFICATE,
                'sha256': hashlib.sha256(self.signed[abi]).hexdigest(), 'sizeBytes': len(self.signed[abi])}
            if abi is not None:
                report['abi'] = abi
            self.reports[abi] = report
            (self.dist / restore.verification_name(abi)).write_text(json.dumps(report))
        self.archive = self.root / 'candidate.zip'
        with zipfile.ZipFile(self.archive, 'w', compression=zipfile.ZIP_DEFLATED) as bundle:
            for abi, data in self.candidates.items():
                bundle.writestr(restore.apk_name('0.40.0', abi, candidate=True), data)
        previous = updates.build_manifest(self.dist / restore.apk_name('0.40.0'), self.reports[None], self.pubspec)
        previous.update(versionName='0.39.0', versionCode=39,
            apkUrl=restore.RELEASE_ROOT+'/download/v0.39.0/Pushok-Flow-v0.39.0.apk')
        self.previous = self.root / 'previous.json'
        self.previous.write_text(json.dumps(previous))
        notes = self.root / 'notes.md'
        notes.write_text('Four standalone APKs; physical-device acceptance pending.')
        self.staging = self.root / 'staging.json'
        self.args = SimpleNamespace(candidate_zip=self.archive,
            signed_apk=self.dist / restore.apk_name('0.40.0'),
            verified=self.dist / restore.verification_name(), pubspec=self.pubspec,
            previous_manifest=self.previous, notes=notes, output=self.staging,
            source_run_id=101, checks_run_id=102, artifact_id=103,
            artifact_size=self.archive.stat().st_size,
            artifact_sha256=hashlib.sha256(self.archive.read_bytes()).hexdigest(),
            source_commit='ab'*20, variants_dir=self.dist)
        with mock.patch('builtins.print'):
            create.create(self.args)
        self.document = restore.read_staging(self.staging, '0.40.0')
        updates.stage(self.args.signed_apk, self.args.verified, self.pubspec, self.dist, self.dist)

    def asset_metadata(self):
        return [{'name': name, 'state': 'uploaded', **reference}
                for name, reference in publish.asset_expectations(self.document, self.dist).items()]

    def test_round_trip_restores_all_exact_signed_apks_and_preserves_legacy_manifest(self):
        self.assertEqual(self.document['schemaVersion'], 2)
        self.assertEqual(set(self.document['variants']), set(restore.ABIS))
        target = self.root / 'restored'
        with mock.patch('builtins.print'):
            restore.restore_all(self.staging, self.archive, target)
        for abi, _, payload in restore.release_payloads(self.document):
            self.assertEqual((target / payload['release']['apkName']).read_bytes(), self.signed[abi])
        manifest = restore.validate_manifest(json.loads((self.dist / 'update.json').read_text()))
        self.assertEqual(manifest['schemaVersion'], 1)
        self.assertEqual(len(manifest), 9)
        self.assertEqual(manifest['apkUrl'], restore.RELEASE_ROOT+'/download/v0.40.0/Pushok-Flow-v0.40.0.apk')
        self.assertEqual(len(restore.public_asset_names(self.document)), 9)
        self.assertFalse(any(p.name.startswith('update-') for p in self.dist.iterdir()))
        publish.verify_local_assets(self.document, self.dist)

    def test_schema_one_still_restores_only_universal_and_has_three_assets(self):
        document, candidate, signed = legacy_fixture()
        archive = self.root / 'old.zip'
        with zipfile.ZipFile(archive, 'w') as bundle:
            bundle.writestr(document['sourceArtifact']['entryName'], candidate)
        document['sourceArtifact'].update(zipSizeBytes=archive.stat().st_size,
            zipSha256=hashlib.sha256(archive.read_bytes()).hexdigest())
        old = self.root / 'old.json'
        old.write_text(json.dumps(document))
        with mock.patch('builtins.print'):
            restore.restore_all(old, archive, self.root / 'old-dist')
        self.assertEqual((self.root / 'old-dist' / document['release']['apkName']).read_bytes(), signed)
        self.assertEqual(len(restore.public_asset_names(document)), 3)

    def test_variant_set_names_and_candidate_paths_fail_closed(self):
        mutations = [
            lambda d: d['variants'].pop('arm64-v8a'),
            lambda d: d['variants'].update({'arm64': d['variants']['arm64-v8a']}),
            lambda d: d['variants']['arm64-v8a'].update(entryName='../other.apk'),
            lambda d: d['variants']['arm64-v8a'].update(entryName=d['sourceArtifact']['entryName']),
            lambda d: d['variants']['arm64-v8a']['release'].update(apkName='Pushok-Flow-v0.40.0-x86_64.apk'),
            lambda d: d.update(schemaVersion=1),
            lambda d: d.update(schemaVersion=True),
            lambda d: d['variants']['arm64-v8a'].update(extra='unexpected'),
        ]
        for mutation in mutations:
            document = copy.deepcopy(self.document)
            mutation(document)
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                restore.validate_staging(document)

    def test_every_variant_must_share_release_identity_and_bounds(self):
        changes = [{'versionCode': 41}, {'versionName': '0.41.0'}, {'packageName': 'other.app'},
            {'certificateSha256': 'cd'*32}, {'minSdk': 25}, {'tag': 'v0.41.0'},
            {'sizeBytes': True}, {'sizeBytes': restore.MAX_APK_BYTES+1}]
        for abi in restore.ABIS:
            for change in changes:
                document = copy.deepcopy(self.document)
                document['variants'][abi]['release'].update(change)
                with self.subTest(abi=abi, change=change), self.assertRaises(ValueError):
                    restore.validate_staging(document)

    def test_each_variant_delta_checks_candidate_literals_output_and_ranges(self):
        for abi in restore.ABIS:
            original = self.document['variants'][abi]
            with self.subTest(abi=abi), self.assertRaises(ValueError):
                restore.restore_bytes(self.candidates[abi]+b'changed', original)
            for mutation in (
                lambda v: v['release'].update(sha256='00'*32),
                lambda v: v['literals'].update(data='not-base64'),
                lambda v: v['operations'][0].__setitem__(1, -1),
            ):
                payload = copy.deepcopy(original)
                mutation(payload)
                with self.assertRaises((ValueError, TypeError)):
                    restore.restore_bytes(self.candidates[abi], payload)

    def test_restoration_refuses_any_existing_target_before_writing_other_apks(self):
        target = self.root / 'restored'
        target.mkdir()
        existing = target / restore.apk_name('0.40.0', 'x86_64')
        existing.write_bytes(b'user reviewed bytes')
        with self.assertRaisesRegex(ValueError, 'overwrite'):
            restore.restore_all(self.staging, self.archive, target)
        self.assertEqual(list(target.iterdir()), [existing])
        self.assertEqual(existing.read_bytes(), b'user reviewed bytes')

    def test_duplicate_variant_archive_entry_is_rejected(self):
        abi = 'arm64-v8a'
        archive = self.root / 'duplicate.zip'
        with zipfile.ZipFile(archive, 'w') as bundle:
            name = restore.apk_name('0.40.0', abi, candidate=True)
            bundle.writestr(name, self.candidates[abi])
            with self.assertWarns(UserWarning):
                bundle.writestr(name, self.candidates[abi])
        artifact = {**self.document['sourceArtifact'], 'entryName': name,
            'zipSizeBytes': archive.stat().st_size, 'zipSha256': hashlib.sha256(archive.read_bytes()).hexdigest()}
        with self.assertRaisesRegex(ValueError, 'candidate archive entry'):
            restore.candidate_bytes(archive, artifact, self.document['variants'][abi]['candidate'])

    def test_signing_delta_rejects_changed_variant_code(self):
        with self.assertRaisesRegex(ValueError, 'payload'):
            create.make_delta(self.candidates['arm64-v8a'], zipped(payload=b'changed program'))

    def test_manifest_staging_validates_all_variant_inputs_before_writing(self):
        report_path = self.dist / restore.verification_name('x86_64')
        original = report_path.read_text()
        for value in ([], {**self.reports['x86_64'], 'abi': 'arm64-v8a'},
                      {**self.reports['x86_64'], 'certificateSha256': 'cd'*32},
                      {**self.reports['x86_64'], 'versionCode': 41}):
            report_path.write_text(json.dumps(value))
            target = self.root / 'not-created'
            with self.subTest(value=value), self.assertRaises(ValueError):
                updates.stage(self.args.signed_apk, self.args.verified, self.pubspec, target, self.dist)
            self.assertFalse(target.exists())
        report_path.write_text(original)

    def test_variant_local_report_apk_and_checksum_tampering_are_rejected(self):
        for abi in restore.ABIS:
            paths = [self.dist / restore.apk_name('0.40.0', abi),
                     self.dist / (restore.apk_name('0.40.0', abi)+'.sha256'),
                     self.dist / restore.verification_name(abi)]
            for path in paths:
                original = path.read_bytes()
                path.write_bytes(b'changed bytes' if path.suffix != '.json' else b'{}')
                with self.subTest(path=path.name), self.assertRaises(ValueError):
                    publish.verify_local_assets(self.document, self.dist)
                path.write_bytes(original)

    def test_uploaded_variant_assets_require_complete_exact_set_and_canonical_urls(self):
        assets = self.asset_metadata()
        publish.validate_assets({'assets': assets}, self.document, self.dist)
        changes = [assets[:-1], assets+[assets[0]], assets[:3],
                   [{**assets[0], 'name': []}]+assets[1:]]
        for field, value in (('digest', 'sha256:'+'00'*32), ('state', 'new'),
                             ('size', True), ('browser_download_url', 'https://other.invalid/file.apk')):
            changed = copy.deepcopy(assets)
            changed[2][field] = value
            changes.append(changed)
        for changed in changes:
            with self.subTest(assets=changed[:1]), self.assertRaises(ValueError):
                publish.validate_assets({'assets': changed}, self.document, self.dist)

    def test_public_discovery_validates_all_nine_assets_without_credentials(self):
        data = {'id': 123, 'tag_name': 'v0.40.0', 'draft': False, 'prerelease': False,
                'published_at': '2026-11-22T17:00:00Z', 'assets': self.asset_metadata()}
        opener = mock.Mock()
        opener.open.return_value = Response(json.dumps(data).encode())
        observation = {}
        with mock.patch.dict(os.environ, {'GH_TOKEN': 'DO_NOT_SEND'}), \
                mock.patch.object(publish.urllib.request, 'build_opener', return_value=opener):
            tag = publish.public_latest_release(observation, publish.asset_expectations(self.document, self.dist))
        self.assertEqual(tag, 'v0.40.0')
        self.assertEqual(len(observation['verifiedAssets']), 9)
        headers = dict(opener.open.call_args.args[0].header_items())
        self.assertNotIn('authorization', {key.lower() for key in headers})
        data['assets'].pop()
        opener.open.return_value = Response(json.dumps(data).encode())
        with mock.patch.object(publish.urllib.request, 'build_opener', return_value=opener):
            with self.assertRaisesRegex(ValueError, 'expected assets'):
                publish.public_latest_release({}, publish.asset_expectations(self.document, self.dist))

    def test_publisher_uploads_all_nine_assets_before_publication(self):
        tag = {'object': {'type': 'commit', 'sha': self.document['sourceCommit']}}
        draft = release_metadata(self.document, self.dist)
        final = release_metadata(self.document, self.dist, draft=False)
        with mock.patch.object(publish, 'preflight'), mock.patch.object(publish, 'require_previous'), \
                mock.patch.object(publish, 'upload_asset', return_value={}) as upload, \
                mock.patch.object(publish, 'api', side_effect=[tag, {**draft, 'assets': []}, draft, tag, draft, final]) as api, \
                mock.patch('builtins.print'):
            publish.publish(self.document, self.dist, self.root)
        self.assertEqual([call.args[1].name for call in upload.call_args_list], restore.public_asset_names(self.document))
        self.assertEqual(api.call_args_list[-1].args[:2], ('releases/765', 'PATCH'))

    def recovery_plan(self):
        draft = release_metadata(self.document, self.dist)
        return {'schemaVersion': 1, 'repository': restore.REPOSITORY,
            'tag': self.document['release']['tag'], 'sourceCommit': self.document['sourceCommit'],
            'releaseId': draft['id'], 'stagingSha256': hashlib.sha256(self.staging.read_bytes()).hexdigest(),
            'assetIds': {item['name']: item['id'] for item in draft['assets']}}

    def test_recovery_descriptor_requires_exact_identity_staging_and_unique_complete_ids(self):
        plan = self.recovery_plan()
        publish.validate_recovery_plan(plan, self.document, plan['stagingSha256'])
        changes = [lambda p: p.update(extra=True), lambda p: p.update(schemaVersion=True),
            lambda p: p.update(repository='other/repo'), lambda p: p.update(tag='v0.39.0'),
            lambda p: p.update(sourceCommit='00'*20), lambda p: p.update(stagingSha256='00'*32),
            lambda p: p.update(releaseId=True), lambda p: p.update(releaseId=0),
            lambda p: p.update(releaseId=2**63), lambda p: p.update(releaseId='765'),
            lambda p: p['assetIds'].pop('update.json'),
            lambda p: p['assetIds'].update({'update.json': True}),
            lambda p: p['assetIds'].update({'update.json': 0}),
            lambda p: p['assetIds'].update({'update.json': 2**63}),
            lambda p: p['assetIds'].update({'update.json': p['assetIds'][restore.apk_name('0.40.0')]})]
        for change in changes:
            broken = copy.deepcopy(plan)
            change(broken)
            with self.subTest(plan=broken), self.assertRaises(ValueError):
                publish.validate_recovery_plan(broken, self.document, plan['stagingSha256'])

    def test_only_unchanged_head_tracked_canonical_recovery_file_can_enable_resume(self):
        staging = self.root/'release-staging'/'v0.40.0.json'
        staging.parent.mkdir()
        staging.write_bytes(self.staging.read_bytes())
        plan = self.recovery_plan()
        path = staging.with_name('v0.40.0-resume.json')
        self.assertIsNone(publish.read_recovery_plan(staging, self.document))
        path.write_text(json.dumps(plan))
        with mock.patch.object(publish.subprocess, 'run', return_value=SimpleNamespace(returncode=0, stdout=path.read_bytes())) as git:
            self.assertEqual(publish.read_recovery_plan(staging, self.document), plan)
        self.assertEqual(git.call_args.args[0], ['git', 'show', 'HEAD:release-staging/v0.40.0-resume.json'])
        for result in (SimpleNamespace(returncode=1, stdout=b''), SimpleNamespace(returncode=0, stdout=b'changed')):
            with mock.patch.object(publish.subprocess, 'run', return_value=result), self.assertRaises(ValueError):
                publish.read_recovery_plan(staging, self.document)
        for raw in ('{}', '{"schemaVersion":1,"schemaVersion":1}'):
            path.write_text(raw)
            with self.assertRaises(ValueError):
                publish.read_recovery_plan(staging, self.document)
        path.unlink()
        path.symlink_to(self.staging)
        with self.assertRaises(ValueError):
            publish.read_recovery_plan(staging, self.document)

    def test_draft_urls_are_bound_to_validated_actual_html_slug(self):
        draft = release_metadata(self.document, self.dist)
        publish.validate_draft_assets(draft, self.document, self.dist, 765)
        canonical = release_metadata(self.document, self.dist, slug='v0.40.0')
        publish.validate_draft_assets(canonical, self.document, self.dist, 765)
        changes = [lambda d: d.update(html_url=d['html_url']+'/'),
            lambda d: d.update(html_url=d['html_url']+'?other=1'),
            lambda d: d.update(html_url=d['html_url'].replace('github.com', 'other.invalid')),
            lambda d: d.update(html_url=d['html_url'].replace('Pushok-Flow', 'other')),
            lambda d: d.update(html_url=d['html_url'].replace('untagged-', 'untagged-%61')),
            lambda d: d.update(html_url=d['html_url'].replace('untagged-118a6cb2049c401d4260', 'v0.39.0')),
            lambda d: d['assets'][0].update(browser_download_url=d['assets'][0]['browser_download_url'].replace('118a6cb2049c401d4260', 'abc')),
            lambda d: d['assets'][0].update(browser_download_url=d['assets'][0]['browser_download_url']+'#fragment'),
            lambda d: d['assets'][0].update(browser_download_url=d['assets'][0]['browser_download_url']+'?query=1')]
        for change in changes:
            broken = copy.deepcopy(draft)
            change(broken)
            with self.subTest(draft=broken['html_url']), self.assertRaises(ValueError):
                publish.validate_draft_assets(broken, self.document, self.dist, 765)
        with self.assertRaises(ValueError):
            publish.validate_assets(draft, self.document, self.dist, require_urls=True)

    def run_recovery(self, *, first=None, last=None, final=None, failed_ci=False, changed_previous=False, error=False):
        draft = release_metadata(self.document, self.dist)
        first = first or draft
        last = last or first
        final = final or release_metadata(self.document, self.dist, draft=False)
        tag = {'object': {'type': 'commit', 'sha': self.document['sourceCommit']}}
        prior = self.document['previousManifest']
        reads = 0
        def api(resource, method='GET', payload=None, missing=False):
            nonlocal reads
            if method == 'PATCH':
                self.assertEqual(resource, 'releases/765')
                self.assertEqual(payload, {'draft': False, 'prerelease': False, 'make_latest': 'true'})
                return final
            self.assertEqual(method, 'GET', 'Recovery must not create, replace or delete anything')
            if resource == 'git/ref/tags/v0.40.0':
                return tag
            if resource == 'releases/765':
                reads += 1
                return first if reads == 1 else last
            if resource == 'releases/latest':
                return {'tag_name': 'v'+prior['versionName'], 'draft': False, 'prerelease': False}
            if resource.startswith('actions/runs/'):
                workflow = '.github/workflows/android-candidate.yml' if resource.endswith('/101') else '.github/workflows/source-checks.yml'
                return {'status': 'completed', 'conclusion': 'failure' if failed_ci else 'success',
                    'head_sha': self.document['sourceCommit'], 'head_branch': 'main', 'event': 'push', 'path': workflow,
                    'repository': {'full_name': restore.REPOSITORY}, 'head_repository': {'full_name': restore.REPOSITORY}}
            if resource == 'actions/artifacts/103':
                artifact = self.document['sourceArtifact']
                return {'id': 103, 'name': artifact['name'], 'expired': False,
                    'size_in_bytes': artifact['zipSizeBytes'], 'digest': 'sha256:'+artifact['zipSha256'],
                    'workflow_run': {'id': 101, 'head_sha': self.document['sourceCommit']}}
            self.fail('Unexpected recovery API resource: '+resource)
        self.recovery_attempt = getattr(self, 'recovery_attempt', 0)+1
        diagnostics = self.root/f'recovery-{self.recovery_attempt}'
        observed_previous = {**prior, 'sha256': '00'*32} if changed_previous else prior
        with mock.patch.object(publish, 'api', side_effect=api) as called, \
                mock.patch.object(publish, 'public_manifest', return_value=(observed_previous, b'')), \
                mock.patch.object(publish, 'upload_asset') as uploaded, mock.patch('builtins.print'):
            if error:
                with self.assertRaises(ValueError):
                    publish.publish(self.document, self.dist, diagnostics, self.recovery_plan())
            else:
                publish.publish(self.document, self.dist, diagnostics, self.recovery_plan())
            uploaded.assert_not_called()
        return called.call_args_list

    def test_exact_complete_draft_recovery_only_patches_after_rechecking_every_gate(self):
        calls = self.run_recovery()
        mutations = [call for call in calls if len(call.args) > 1 and call.args[1] != 'GET']
        self.assertEqual(len(mutations), 1)
        self.assertEqual(mutations[0].args[:2], ('releases/765', 'PATCH'))
        self.assertEqual(calls[-2].args, ('releases/765',))
        resources = [call.args[0] for call in calls]
        self.assertIn('actions/runs/101', resources)
        self.assertIn('actions/runs/102', resources)
        self.assertIn('actions/artifacts/103', resources)

    def test_recovery_rejects_changed_identity_ids_partial_uploads_ci_or_channel_before_patch(self):
        changes = [lambda d: d.update(id=999), lambda d: d.update(draft=False),
            lambda d: d.update(prerelease=True), lambda d: d.update(published_at='2026-11-21T00:00:00Z'),
            lambda d: d.update(target_commitish='00'*20), lambda d: d.update(tag_name='v0.41.0'),
            lambda d: d.update(name='Different release'), lambda d: d.update(body='Changed notes'),
            lambda d: d['assets'].pop(), lambda d: d['assets'][0].update(id=99999),
            lambda d: d['assets'][0].update(digest='sha256:'+'00'*32),
            lambda d: d['assets'][0].update(size=d['assets'][0]['size']+1)]
        for change in changes:
            draft = release_metadata(self.document, self.dist)
            change(draft)
            with self.subTest(change=change):
                calls = self.run_recovery(first=draft, error=True)
                self.assertFalse(any(len(call.args) > 1 and call.args[1] != 'GET' for call in calls))
        for options in ({'failed_ci': True}, {'changed_previous': True}):
            calls = self.run_recovery(**options, error=True)
            self.assertFalse(any(len(call.args) > 1 and call.args[1] != 'GET' for call in calls))

    def test_recovery_rechecks_asset_ids_and_identity_immediately_before_patch(self):
        for change in (lambda d: d['assets'][0].update(id=99999, url=publish.API_ROOT+'releases/assets/99999'),
                       lambda d: d.update(body='Changed during verification'),
                       lambda d: d.update(target_commitish='00'*20)):
            final_read = release_metadata(self.document, self.dist)
            change(final_read)
            calls = self.run_recovery(last=final_read, error=True)
            self.assertFalse(any(len(call.args) > 1 and call.args[1] != 'GET' for call in calls))

    def test_published_response_must_keep_canonical_urls_and_original_asset_ids(self):
        final = release_metadata(self.document, self.dist, draft=False)
        final['assets'][0]['browser_download_url'] = release_metadata(self.document, self.dist)['assets'][0]['browser_download_url']
        self.run_recovery(final=final, error=True)
        final = release_metadata(self.document, self.dist, draft=False)
        final['assets'][0]['id'] += 100
        self.run_recovery(final=final, error=True)
        final = release_metadata(self.document, self.dist, draft=False)
        final['assets'][0]['id'] = float(final['assets'][0]['id'])
        self.run_recovery(final=final, error=True)

    def run_downloads(self, corrupt=None, denied=None):
        seen = []
        opener = mock.Mock()
        def open_request(request, **kwargs):
            seen.append(request)
            name = request.full_url.rsplit('/', 1)[-1]
            if name == denied:
                raise urllib.error.HTTPError(request.full_url+'?secret=DO_NOT_LOG', 403, 'DO_NOT_LOG', {}, None)
            raw = (self.dist / name).read_bytes()
            return Response(raw+b'extra' if name == corrupt else raw)
        opener.open.side_effect = open_request
        with mock.patch.dict(os.environ, {'GH_TOKEN': 'DO_NOT_SEND'}), \
                mock.patch.object(publish.urllib.request, 'build_opener', return_value=opener), \
                mock.patch('builtins.print'):
            if corrupt or denied:
                with self.assertRaisesRegex(ValueError, 'could not be verified'):
                    publish.verify_public_downloads(self.document, self.dist, self.root / 'diagnostics')
            else:
                publish.verify_public_downloads(self.document, self.dist, self.root / 'diagnostics')
        report_path = self.root / 'diagnostics/public-asset-observations.json'
        report = json.loads(report_path.read_text())
        self.assertNotIn('DO_NOT_LOG', report_path.read_text())
        self.assertEqual(len(seen), 8)
        for request in seen:
            self.assertFalse({'authorization', 'cookie'} & {key.lower() for key, _ in request.header_items()})
        self.assertEqual(len({request.full_url for request in seen}), 8)
        return report

    def test_public_downloads_hash_all_four_apks_and_checksums_anonymously(self):
        report = self.run_downloads()
        self.assertEqual(report['status'], 'passed')
        self.assertEqual(len(report['assets']), 8)
        self.assertTrue(all(item['matches'] for item in report['assets'].values()))

    def test_public_download_tampering_or_denial_cannot_report_success(self):
        for kind in ('corrupt', 'denied'):
            name = restore.apk_name('0.40.0', 'arm64-v8a')
            report = self.run_downloads(**{kind: name})
            self.assertEqual(report['status'], 'not_verified')
            self.assertFalse(report['assets'][name]['matches'])


if __name__ == '__main__':
    unittest.main()
