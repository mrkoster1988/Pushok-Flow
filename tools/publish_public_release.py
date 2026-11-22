#!/usr/bin/env python3
"""Publish only a tracked, locally signed and CI-verified public APK."""
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
import hashlib
import http.client
import json
import os
from pathlib import Path
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

from restore_public_release import (CERTIFICATE, MANIFEST_URL, REPOSITORY,
    manifest, public_asset_names, read_json, read_staging, release_payloads,
    require, validate_manifest, verification_name, version)

API_ROOT = f'https://api.github.com/repos/{REPOSITORY}/'
API_VERSION = '2026-03-10'
MAX_API_BYTES = 2 * 1024 * 1024
# The v0.31/v0.32 latest redirect stayed stale beyond the old 35-second
# interval window. Allow bounded CDN propagation without accepting old bytes.
PUBLIC_MANIFEST_ATTEMPTS = 24
PUBLIC_MANIFEST_RETRY_SECONDS = 5


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ValueError('Authenticated GitHub metadata redirected unexpectedly')


def api(resource, method='GET', payload=None, missing=False):
    require(resource and not resource.startswith('/') and '..' not in resource, 'Unexpected API resource')
    token = os.environ.get('GH_TOKEN')
    require(bool(token), 'GH_TOKEN is required for release administration')
    headers = {'Authorization': 'Bearer '+token, 'Accept': 'application/vnd.github+json',
               'X-GitHub-Api-Version': API_VERSION, 'User-Agent': 'Pushok-Flow-Release'}
    data = None
    if payload is not None:
        data = json.dumps(payload).encode()
        headers['Content-Type'] = 'application/json'
    request = urllib.request.Request(API_ROOT+resource, data=data, headers=headers, method=method)
    try:
        with urllib.request.build_opener(NoRedirect()).open(request, timeout=30) as response:
            raw = response.read(MAX_API_BYTES+1)
    except urllib.error.HTTPError as error:
        if missing and error.code == 404:
            return None
        raise ValueError(f'GitHub release API failed: HTTP {error.code}') from None
    require(len(raw) <= MAX_API_BYTES, 'GitHub response too large')
    return json.loads(raw)


def _public_url_for_log(url):
    # CDN redirects contain signed query strings; preserve only host and path.
    parsed = urllib.parse.urlsplit(url)
    return urllib.parse.urlunsplit((parsed.scheme, parsed.netloc, parsed.path, '', ''))


def public_manifest(observation=None, request_url=MANIFEST_URL):
    # Deliberately no token/session. This is the address installed v0.24 uses.
    prefix = f'https://github.com/{REPOSITORY}/releases/download/v'
    pinned_version = request_url[len(prefix):-len('/update.json')] if (
        request_url.startswith(prefix) and request_url.endswith('/update.json')) else None
    require(request_url == MANIFEST_URL or version(pinned_version), 'Unexpected public manifest URL')
    if observation is not None:
        observation.update(requestUrl=request_url,
            requestedAt=datetime.now(timezone.utc).isoformat())
    request = urllib.request.Request(request_url, headers={
        'Accept': 'application/json', 'User-Agent': 'Pushok-Flow-Public-Check',
        'Cache-Control': 'no-cache, max-age=0', 'Pragma': 'no-cache'})
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            require(response.getcode() == 200, 'Public manifest did not return HTTP 200')
            raw = response.read(65537)
            if observation is not None:
                observation.update(httpStatus=response.getcode(),
                    finalUrl=_public_url_for_log(response.geturl()),
                    sizeBytes=len(raw), sha256=hashlib.sha256(raw).hexdigest(),
                    cacheControl=response.headers.get('Cache-Control', '')[:256],
                    age=response.headers.get('Age', '')[:64])
    except urllib.error.HTTPError as error:
        if observation is not None:
            observation.update(httpStatus=error.code,
                finalUrl=_public_url_for_log(error.geturl()), failure='HTTP_ERROR')
        raise
    except OSError:
        if observation is not None:
            observation['failure'] = 'NETWORK_ERROR'
        raise
    require(len(raw) <= 65536, 'Public manifest too large')
    try:
        decoded = json.loads(raw)
        if observation is not None and type(decoded) is dict:
            seen_version = decoded.get('versionName')
            seen_build = decoded.get('versionCode')
            observation['observedVersion'] = seen_version if version(seen_version) else 'invalid'
            observation['observedBuild'] = seen_build if type(seen_build) is int and 0 <= seen_build <= 2_100_000_000 else None
        result = validate_manifest(decoded)
    except (ValueError, TypeError):
        if observation is not None:
            observation['failure'] = 'INVALID_MANIFEST'
        raise
    return result, raw


def public_latest_release(observation, expected_assets=None):
    """Read the v0.31 discovery endpoint without a token, cookie or session."""
    url = API_ROOT + 'releases/latest'
    observation.update(requestUrl=url, requestedAt=datetime.now(timezone.utc).isoformat())
    request = urllib.request.Request(url, headers={
        'Accept': 'application/vnd.github+json', 'X-GitHub-Api-Version': API_VERSION,
        'User-Agent': 'Pushok-Flow-Public-Check', 'Cache-Control': 'no-cache, max-age=0',
        'Pragma': 'no-cache'})
    try:
        with urllib.request.build_opener(NoRedirect()).open(request, timeout=20) as response:
            require(response.getcode() == 200, 'Public release metadata did not return HTTP 200')
            raw = response.read(256 * 1024 + 1)
            observation.update(httpStatus=response.getcode(), sizeBytes=len(raw),
                sha256=hashlib.sha256(raw).hexdigest(), age=response.headers.get('Age', '')[:64])
    except urllib.error.HTTPError as error:
        observation.update(httpStatus=error.code, failure='HTTP_ERROR',
            retryAfter=(error.headers.get('Retry-After', '') if error.headers else '')[:64],
            rateLimitReset=(error.headers.get('X-RateLimit-Reset', '') if error.headers else '')[:64])
        raise
    require(len(raw) <= 256 * 1024, 'Public release metadata too large')
    release = json.loads(raw)
    require(type(release) is dict, 'Invalid public release metadata')
    tag = release.get('tag_name')
    require(type(release.get('id')) is int and release['id'] > 0
        and type(tag) is str and tag.startswith('v') and version(tag[1:])
        and release.get('draft') is False and release.get('prerelease') is False
        and type(release.get('published_at')) is str
        and re.fullmatch(r'[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z', release['published_at']),
        'The release is not a published stable version')
    observation['observedTag'] = tag
    if expected_assets is not None:
        validate_asset_metadata(release.get('assets'), expected_assets, require_urls=True)
        observation['verifiedAssets'] = [
            {'name': name, 'sizeBytes': item['size'], 'digest': item['digest']}
            for name, item in expected_assets.items()]
    return tag


def require_previous(document):
    latest = api('releases/latest')
    previous = document['previousManifest']
    require(latest.get('draft') is False and latest.get('prerelease') is False
            and latest.get('tag_name') == 'v'+previous['versionName'], 'Published latest changed; review before release')
    current, _ = public_manifest()
    require(current == previous, 'Published update manifest changed; review before release')
    return latest


def require_absent(tag):
    require(api('git/ref/tags/'+tag, missing=True) is None, 'Release tag already exists; never overwrite')
    require(api('releases/tags/'+tag, missing=True) is None, 'Published release already exists; never overwrite')
    # Tag lookup excludes drafts. Enumerate authenticated releases to reject them too.
    for page in range(1, 21):
        releases = api(f'releases?per_page=100&page={page}')
        require(type(releases) is list, 'Invalid release listing')
        require(not any(item.get('tag_name') == tag for item in releases), 'Release or draft already exists; inspect it before retrying')
        if len(releases) < 100:
            return
    raise ValueError('Too many releases to verify absence safely')


def validate_run(run, document, workflow):
    require(run.get('status') == 'completed' and run.get('conclusion') == 'success', 'CI run is not successful')
    require(run.get('head_sha') == document['sourceCommit'] and run.get('head_branch') == 'main'
            and run.get('event') == 'push' and run.get('path') == workflow, 'CI run is not the exact approved main build')
    require(run.get('repository', {}).get('full_name') == REPOSITORY
            and run.get('head_repository', {}).get('full_name') == REPOSITORY, 'CI run belongs to another repository')


def validate_artifact(artifact, document):
    expected = document['sourceArtifact']
    require(artifact.get('id') == expected['id'] and artifact.get('name') == expected['name']
            and artifact.get('expired') is False and artifact.get('size_in_bytes') == expected['zipSizeBytes']
            and artifact.get('digest') == 'sha256:'+expected['zipSha256'], 'Candidate artifact differs')
    require(artifact.get('workflow_run', {}).get('id') == document['sourceRunId']
            and artifact.get('workflow_run', {}).get('head_sha') == document['sourceCommit'], 'Artifact belongs to another source build')


def preflight(document, diagnostics):
    require_absent(document['release']['tag'])
    latest = require_previous(document)
    source = api(f'actions/runs/{document["sourceRunId"]}')
    checks = api(f'actions/runs/{document["sourceChecksRunId"]}')
    validate_run(source, document, '.github/workflows/android-candidate.yml')
    validate_run(checks, document, '.github/workflows/source-checks.yml')
    artifact = api(f'actions/artifacts/{document["sourceArtifact"]["id"]}')
    validate_artifact(artifact, document)
    diagnostics.mkdir(parents=True, exist_ok=True)
    for name, data in [('source-run', source), ('source-checks-run', checks), ('source-artifact', artifact), ('previous-release', latest)]:
        (diagnostics/(name+'.json')).write_text(json.dumps(data, indent=2)+'\n')
    output = os.environ.get('GITHUB_OUTPUT')
    if output:
        with open(output, 'a', encoding='utf-8') as stream:
            stream.write(f'source_sha={document["sourceCommit"]}\nartifact_id={document["sourceArtifact"]["id"]}\nrelease_apk={document["release"]["apkName"]}\n')
    print('Both CI runs, source artifact and previous public update channel confirmed.')


def asset_expectations(document, dist):
    result = {}
    for name in public_asset_names(document):
        local = dist/name
        with local.open('rb') as stream:
            digest = hashlib.file_digest(stream, 'sha256').hexdigest()
        result[name] = {'size': local.stat().st_size, 'digest': 'sha256:'+digest,
            'browser_download_url': f'https://github.com/{REPOSITORY}/releases/download/' + document['release']['tag'] + '/' + name}
    return result


def validate_asset_metadata(assets, expected, require_urls=False):
    require(type(assets) is list and all(type(asset) is dict and type(asset.get('name')) is str for asset in assets)
            and len(assets) == len(expected) and {a.get('name') for a in assets} == set(expected),
            'Release must contain exactly the expected assets')
    for asset in assets:
        reference = expected[asset['name']]
        require(asset.get('state') == 'uploaded' and type(asset.get('size')) is int
                and asset['size'] == reference['size'] and asset.get('digest') == reference['digest'],
                'Uploaded asset differs from verified bytes')
        if require_urls:
            require(asset.get('browser_download_url') == reference['browser_download_url'],
                    'Uploaded asset has an unexpected download URL')


def validate_assets(release, document, dist):
    validate_asset_metadata(release.get('assets'), asset_expectations(document, dist),
                            require_urls=document['schemaVersion'] == 2)


def verify_local_assets(document, dist):
    expected = manifest(document['release'])
    require(read_json(dist/'update.json', 65536) == expected, 'Final update manifest differs from approved staging')
    for abi, _, payload in release_payloads(document):
        reference = manifest(payload['release'])
        verification = read_json(dist/verification_name(abi))
        require(type(verification) is dict, 'Invalid APK verification report')
        require(verification.get('abi') == abi, 'APK verification architecture differs')
        for field in ('packageName', 'versionName', 'versionCode', 'minSdk', 'sizeBytes', 'sha256', 'certificateSha256'):
            require(verification.get(field) == reference[field], 'APK verification report differs: '+field)
        apk = dist/payload['release']['apkName']
        require(apk.stat().st_size == reference['sizeBytes'], 'APK changed after verification')
        with apk.open('rb') as stream:
            require(hashlib.file_digest(stream, 'sha256').hexdigest() == reference['sha256'], 'APK changed after verification')
        checksum = dist/(apk.name+'.sha256')
        require(checksum.read_text() == reference['sha256']+'  '+apk.name+'\n', 'APK checksum file differs')


def upload_asset(url, path):
    parsed = urllib.parse.urlsplit(url)
    require(parsed.scheme == 'https' and parsed.netloc == 'uploads.github.com'
            and parsed.path.startswith(f'/repos/{REPOSITORY}/releases/')
            and parsed.path.endswith('/assets') and not parsed.fragment, 'Unexpected asset upload destination')
    token = os.environ.get('GH_TOKEN')
    require(bool(token), 'GH_TOKEN is required for asset upload')
    connection = http.client.HTTPSConnection('uploads.github.com', timeout=120)
    try:
        connection.putrequest('POST', parsed.path+'?'+parsed.query)
        for name, value in {'Authorization': 'Bearer '+token, 'Accept': 'application/vnd.github+json',
                'X-GitHub-Api-Version': API_VERSION, 'User-Agent': 'Pushok-Flow-Release',
                'Content-Type': 'application/octet-stream', 'Content-Length': str(path.stat().st_size)}.items():
            connection.putheader(name, value)
        connection.endheaders()
        with path.open('rb') as stream:
            while block := stream.read(64 * 1024):
                connection.send(block)
        response = connection.getresponse()
        raw = response.read(MAX_API_BYTES+1)
        # Redirects are never followed with credentials, including upload failures.
        require(response.status == 201, f'Asset upload failed: HTTP {response.status}; draft retained')
        require(len(raw) <= MAX_API_BYTES, 'Asset upload response too large')
        return json.loads(raw)
    finally:
        connection.close()


def publish(document, dist, diagnostics):
    verify_local_assets(document, dist)
    # Recheck just before the first mutation, including existing drafts and channel races.
    preflight(document, diagnostics)
    tag = document['release']['tag']
    created_tag = api('git/refs', 'POST', {'ref': 'refs/tags/'+tag, 'sha': document['sourceCommit']})
    require(created_tag.get('object', {}).get('type') == 'commit'
            and created_tag['object']['sha'] == document['sourceCommit'], 'Created tag differs')
    release = api('releases', 'POST', {'tag_name': tag, 'target_commitish': document['sourceCommit'],
        'name': 'Pushok Flow '+document['release']['versionName'], 'body': document['notes'],
        'draft': True, 'prerelease': False, 'make_latest': 'false', 'generate_release_notes': False})
    (diagnostics/'release-created.json').write_text(json.dumps(release, indent=2)+'\n')
    release_id = release.get('id')
    require(type(release_id) is int and release_id > 0 and release.get('draft') is True
            and release.get('tag_name') == tag, 'Unexpected created draft')
    expected_upload = f'https://uploads.github.com/repos/{REPOSITORY}/releases/{release_id}/assets'
    require(release.get('upload_url') == expected_upload+'{?name,label}', 'Unexpected upload URL')
    for name in public_asset_names(document):
        url = expected_upload+'?name='+urllib.parse.quote(name, safe='')
        uploaded = upload_asset(url, dist/name)
        (diagnostics/('uploaded-'+name+'.json')).write_text(json.dumps(uploaded, indent=2)+'\n')
    # Always address the numeric ID returned by POST; the tag endpoint excludes drafts.
    draft = api(f'releases/{release_id}')
    require(draft.get('id') == release_id and draft.get('tag_name') == tag
            and draft.get('draft') is True and draft.get('prerelease') is False, 'Draft state changed')
    validate_assets(draft, document, dist)
    current_tag = api('git/ref/tags/'+tag)
    require(current_tag.get('object', {}).get('type') == 'commit'
            and current_tag['object']['sha'] == document['sourceCommit'], 'Release tag changed')
    require_previous(document)
    final = api(f'releases/{release_id}', 'PATCH', {'draft': False, 'prerelease': False, 'make_latest': 'true'})
    require(final.get('id') == release_id and final.get('tag_name') == tag
            and final.get('draft') is False and final.get('prerelease') is False, 'Publication response differs')
    validate_assets(final, document, dist)
    (diagnostics/'release-published.json').write_text(json.dumps(final, indent=2)+'\n')
    print(f'Published {tag}; release ID {release_id}; {len(public_asset_names(document))} verified assets retained.')


def verify_public(document, dist, diagnostics):
    expected = (dist/'update.json').read_bytes()
    require(json.loads(expected) == manifest(document['release']), 'Expected manifest differs')
    diagnostics.mkdir(parents=True, exist_ok=True)
    observations = {'expectedVersion': document['release']['versionName'],
        'expectedSizeBytes': len(expected), 'expectedSha256': hashlib.sha256(expected).hexdigest(),
        'requestUrl': MANIFEST_URL, 'attempts': []}
    for attempt in range(PUBLIC_MANIFEST_ATTEMPTS):
        observation = {'attempt': attempt+1, 'matches': False}
        try:
            current, raw = public_manifest(observation)
            require(raw == expected and current == manifest(document['release']), 'Public updater endpoint has not reached the new release')
            observation['matches'] = True
            (diagnostics/'public-update.json').write_bytes(raw)
            print('Public latest/download/update.json exactly matches the verified release, without credentials.')
            return
        except (OSError, ValueError):
            observation.setdefault('failure', 'MANIFEST_MISMATCH')
            if observation.get('httpStatus') in (403, 429):
                raise ValueError('Public updater endpoint was denied or rate-limited; '
                    f'last HTTP={observation["httpStatus"]}; no immediate retry was attempted') from None
            if attempt == PUBLIC_MANIFEST_ATTEMPTS - 1:
                raise ValueError('Public updater endpoint is not confirmed; '
                    f'last HTTP={observation.get("httpStatus", "unavailable")}, '
                    f'version={observation.get("observedVersion", "unavailable")}; '
                    'inspect public-update-observations.json before reporting success') from None
        finally:
            observations['attempts'].append(observation)
            (diagnostics/'public-update-observations.json').write_text(json.dumps(observations, indent=2)+'\n')
            print('Public updater observation: '+json.dumps(observation, ensure_ascii=False))
        if attempt < PUBLIC_MANIFEST_ATTEMPTS - 1:
            time.sleep(PUBLIC_MANIFEST_RETRY_SECONDS)


def verify_discovery(document, dist, diagnostics):
    """Check release selection and exact pinned bytes used by the new updater."""
    expected = (dist/'update.json').read_bytes()
    require(json.loads(expected) == manifest(document['release']), 'Expected manifest differs')
    diagnostics.mkdir(parents=True, exist_ok=True)
    report = {'expectedTag': document['release']['tag'], 'attempts': []}
    expected_assets = asset_expectations(document, dist) if document['schemaVersion'] == 2 else None
    for attempt in range(4):
        observation = {'attempt': attempt+1, 'release': {}, 'manifest': {}, 'matches': False}
        try:
            tag = (public_latest_release(observation['release'], expected_assets)
                   if expected_assets is not None else public_latest_release(observation['release']))
            require(tag == document['release']['tag'], 'Public release selection has not reached this version')
            url = f'https://github.com/{REPOSITORY}/releases/download/{tag}/update.json'
            current, raw = public_manifest(observation['manifest'], request_url=url)
            require(current['versionName'] == tag[1:] and raw == expected,
                'Pinned public update manifest differs from the selected release')
            observation['matches'] = True
            print('Public release discovery and pinned update.json exactly match the verified release, without credentials.')
            return
        except (OSError, ValueError):
            observation['failure'] = 'DISCOVERY_NOT_CONFIRMED'
            if observation['release'].get('httpStatus') in (403, 429):
                raise ValueError('Public release discovery was rate-limited or denied; no immediate retry was attempted') from None
            if attempt == 3:
                raise ValueError('Public release discovery is not confirmed; inspect update-discovery-observations.json') from None
        finally:
            report['attempts'].append(observation)
            (diagnostics/'update-discovery-observations.json').write_text(json.dumps(report, indent=2)+'\n')
            print('Update discovery observation: '+json.dumps(observation, ensure_ascii=False))
        time.sleep(5)


def verify_public_downloads(document, dist, diagnostics):
    """Hash every public APK and checksum without credentials or retained copies."""
    verify_local_assets(document, dist)
    expected = asset_expectations(document, dist)
    expected.pop('update.json')  # Both manifest discovery paths are checked separately.
    diagnostics.mkdir(parents=True, exist_ok=True)
    report = {'expectedTag': document['release']['tag'], 'anonymousRequests': True,
              'authenticationHeadersSent': False, 'cookieJarUsed': False, 'assets': {}, 'status': 'checking'}

    def fetch(name, reference):
        observation = {'name': name, 'requestUrl': reference['browser_download_url'],
            'requestedAt': datetime.now(timezone.utc).isoformat(), 'matches': False}
        digest = hashlib.sha256()
        size = 0
        try:
            request = urllib.request.Request(reference['browser_download_url'], headers={
                'User-Agent': 'Pushok-Flow-Public-Check',
                'Cache-Control': 'no-cache, max-age=0', 'Pragma': 'no-cache'})
            # Fresh opener has no CookieJar or authentication handler.
            with urllib.request.build_opener().open(request, timeout=30) as response:
                observation.update(httpStatus=response.getcode(), finalUrl=_public_url_for_log(response.geturl()))
                require(response.getcode() == 200, 'Public asset did not return HTTP 200')
                declared = response.headers.get('Content-Length')
                if declared is not None:
                    require(int(declared) == reference['size'], 'Public asset content length differs')
                while chunk := response.read(min(1024*1024, reference['size']-size+1)):
                    size += len(chunk)
                    require(size <= reference['size'], 'Public asset exceeds expected size')
                    digest.update(chunk)
            require(size == reference['size'] and 'sha256:'+digest.hexdigest() == reference['digest'],
                    'Public asset bytes differ')
            observation['matches'] = True
        except (OSError, ValueError, http.client.HTTPException) as error:
            observation['errorType'] = type(error).__name__
            if isinstance(error, urllib.error.HTTPError):
                observation['httpStatus'] = error.code
                observation['finalUrl'] = _public_url_for_log(error.geturl())
            # Do not stringify network exceptions; they may contain signed URLs.
        observation.update(completedAt=datetime.now(timezone.utc).isoformat(),
                           sizeBytes=size, sha256=digest.hexdigest())
        return observation

    with ThreadPoolExecutor(max_workers=4) as pool:
        futures = {pool.submit(fetch, name, reference): name for name, reference in expected.items()}
        for future in as_completed(futures):
            observation = future.result()
            report['assets'][futures[future]] = observation
            print('Public asset observation: '+json.dumps(observation, ensure_ascii=False))
    report['status'] = 'passed' if all(item['matches'] for item in report['assets'].values()) else 'not_verified'
    (diagnostics/'public-asset-observations.json').write_text(json.dumps(report, indent=2)+'\n')
    require(report['status'] == 'passed', 'At least one public APK or checksum could not be verified; inspect public-asset-observations.json')
    print(f'All {len(expected)} public APK/checksum assets exactly match the verified release, without credentials.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('preflight', 'verify-assets', 'publish', 'verify-public', 'verify-discovery', 'verify-downloads'))
    parser.add_argument('--release-version', required=True)
    parser.add_argument('--dist', type=Path, default=Path('dist'))
    parser.add_argument('--diagnostics', type=Path, default=Path('release-diagnostics'))
    args = parser.parse_args()
    try:
        require(version(args.release_version), 'Invalid release version')
        staging = Path('release-staging')/('v'+args.release_version+'.json')
        document = read_staging(staging, args.release_version)
        if args.command == 'preflight':
            preflight(document, args.diagnostics)
        elif args.command == 'verify-assets':
            verify_local_assets(document, args.dist)
        elif args.command == 'publish':
            publish(document, args.dist, args.diagnostics)
        elif args.command == 'verify-public':
            verify_public(document, args.dist, args.diagnostics)
        elif args.command == 'verify-discovery':
            verify_discovery(document, args.dist, args.diagnostics)
        else:
            verify_public_downloads(document, args.dist, args.diagnostics)
    except (OSError, ValueError, KeyError, TypeError, http.client.HTTPException) as error:
        print(f'Public release stopped: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
