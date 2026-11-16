"""Upload missing verified assets to one existing draft without changing it."""
# SPDX-License-Identifier: GPL-3.0-only
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import urllib.error
import urllib.parse
import urllib.request


PINS = json.loads(r'''{
  "repository": "unknownnumbers/rime-stellae",
  "repository_id": 1457038758,
  "source_ref": "e49a6867b3a80427d388f29c3fbe1f4387e3d2f3",
  "source_run": 43750952295,
  "artifact_id": 14177966051,
  "artifact_name": "stellae-rymcp-2026.11.16-release",
  "artifact_bytes": 218039029,
  "artifact_digest": "sha256:f408ebc3cd7aac41ad1f900e23ba39e02b8655686011de7f18cbd70b8923071f",
  "draft_id": 446822325,
  "tag": "v2026.11.16",
  "title": "Stellae 61052 + RymCp 2026.11.16",
  "body_sha256": "acc8b43db57cb69229c723629d57ee520c88ef51f9ad1f1ea77d149ddac03ef3",
  "assets": [
    {
      "name": "7z2405-src.tar.xz",
      "bytes": 1486772,
      "sha256": "63f341cf80b8d287c6e945519b3da0fa75553c85572a471b7fa6e68f9a90b790"
    },
    {
      "name": "bundle-provenance.json",
      "bytes": 119646,
      "sha256": "c06395243b242e499a4e7e81024c4c94f80bc18f68b7a4dec85b2969b838645e"
    },
    {
      "name": "package-license-index.json",
      "bytes": 550329,
      "sha256": "84e8ff9a8c2794da4bab966fc737ad8b6d9ea15a258dbd2e78cfdb22bc93cbe8"
    },
    {
      "name": "package-manifest.json",
      "bytes": 111096,
      "sha256": "f8a9761e02bb8533d176e7cdb6353d4b4108ef27191ddf2135574d95377eeae5"
    },
    {
      "name": "payload-verification.json",
      "bytes": 2661,
      "sha256": "54f857b96e0e9157620432b3802f595a65432297926ee40f253f3fd127c77bed"
    },
    {
      "name": "pe-verification.json",
      "bytes": 8174,
      "sha256": "c4bd391a17a16b3b3b38c9523425ac1a79eafb35ab3c851729b80cd93d422bd7"
    },
    {
      "name": "server-overlay-verification.json",
      "bytes": 1750,
      "sha256": "36bb6d7d78536deca20974956aebdc19d6c03527506c70659150da7109f84d51"
    },
    {
      "name": "SHA256SUMS.txt",
      "bytes": 931,
      "sha256": "e3599d69210bbdacd95c9982c7d3516dad5ea3bdcf1ce79be7a2129f8c38d7d6"
    },
    {
      "name": "stellae-rymcp-2026.11.16-installer.exe",
      "bytes": 110219241,
      "sha256": "a3e83b75a5d9dcc0c0b1cf41bcee6dcf1b97e8972239f25ec060da21f18764fe"
    },
    {
      "name": "stellae-rymcp-2026.11.16-source.zip",
      "bytes": 106174583,
      "sha256": "84969662998ce2c2af1872a88b6c10005ced50a53b37c58413ebf00654c5ca53"
    },
    {
      "name": "validation.json",
      "bytes": 578,
      "sha256": "26f8a92886b3759b0149663bda0f356e7d47aef30b175f452ba360107a8b83dd"
    }
  ]
}''')


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, new_url):
        return None


def sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def require(ok, message):
    if not ok:
        raise RuntimeError(message)


def headers(token):
    return {'Authorization': 'Bearer ' + token, 'Accept': 'application/vnd.github+json',
            'X-GitHub-Api-Version': '2022-11-28', 'User-Agent': 'rime-stellae-reviewed-assets'}


def get_json(path, token, allow_missing=False):
    base = 'repos/' + PINS['repository']
    require(path == base or path.startswith(base + '/'), 'Unexpected metadata endpoint')
    request = urllib.request.Request('https://api.github.com/' + path, headers=headers(token))
    try:
        with urllib.request.build_opener(NoRedirect()).open(request, timeout=120) as response:
            require(response.status == 200, 'Unexpected metadata status')
            return json.load(response)
    except urllib.error.HTTPError as error:
        if allow_missing and error.code == 404:
            return None
        raise RuntimeError('Metadata request failed with HTTP ' + str(error.code)) from None


def remote_assets(release):
    expected = {row['name']: row for row in PINS['assets']}
    found = {}
    for asset in release['assets']:
        name = asset['name']
        require(name in expected and name not in found, 'Unexpected or duplicate draft asset')
        approved = expected[name]
        require(asset['state'] == 'uploaded' and asset['size'] == approved['bytes']
                and asset.get('digest') == 'sha256:' + approved['sha256'],
                'An existing draft asset differs: ' + name)
        found[name] = asset
    return found


def check_draft(token):
    root = 'repos/' + PINS['repository'] + '/'
    release = get_json(root + 'releases/' + str(PINS['draft_id']), token)
    require(release['id'] == PINS['draft_id'] and release['draft'] is True
            and release['tag_name'] == PINS['tag']
            and release['target_commitish'] == PINS['source_ref']
            and release['name'] == PINS['title'], 'The approved draft identity changed')
    require(hashlib.sha256((release['body'] or '').encode()).hexdigest() == PINS['body_sha256'],
            'The approved draft description changed')
    return release, remote_assets(release)


def preflight(token):
    root = 'repos/' + PINS['repository'] + '/'
    repo = get_json(root.rstrip('/'), token)
    require(repo['id'] == PINS['repository_id'] and not repo['private']
            and not repo['archived'] and not repo['fork'], 'The repository identity changed')
    main = get_json(root + 'git/ref/heads/main', token)
    require(main['object']['type'] == 'commit' and main['object']['sha'] == PINS['source_ref'],
            'The approved main source changed')
    run = get_json(root + 'actions/runs/' + str(PINS['source_run']), token)
    require(run['id'] == PINS['source_run'] and run['head_sha'] == PINS['source_ref']
            and run['status'] == 'completed' and run['conclusion'] == 'success'
            and run['path'] == '.github/workflows/bundle.yml'
            and run['repository']['id'] == PINS['repository_id'], 'The successful source run differs')
    artifact = get_json(root + 'actions/artifacts/' + str(PINS['artifact_id']), token)
    require(artifact['id'] == PINS['artifact_id'] and artifact['name'] == PINS['artifact_name']
            and artifact['size_in_bytes'] == PINS['artifact_bytes']
            and artifact['digest'] == PINS['artifact_digest'] and not artifact['expired']
            and artifact['workflow_run']['id'] == PINS['source_run']
            and artifact['workflow_run']['head_sha'] == PINS['source_ref']
            and artifact['workflow_run']['repository_id'] == PINS['repository_id'],
            'The approved artifact metadata differs')
    ref = get_json(root + 'git/ref/tags/' + urllib.parse.quote(PINS['tag'], safe=''), token, True)
    if ref:
        obj = ref['object']
        for _ in range(8):
            if obj['type'] != 'tag':
                break
            obj = get_json(root + 'git/tags/' + obj['sha'], token)['object']
        require(obj['type'] == 'commit' and obj['sha'] == PINS['source_ref'], 'The existing tag differs')
    return check_draft(token)


def check_files(directory):
    directory = directory.resolve(strict=True)
    expected = {row['name']: row for row in PINS['assets']}
    require({path.name for path in directory.iterdir()} == set(expected), 'The artifact file set differs')
    for name, row in expected.items():
        require(re.fullmatch('[A-Za-z0-9_.-]+', name) is not None, 'Invalid approved asset name')
        path = directory / name
        require(path.is_file() and not path.is_symlink() and path.stat().st_size == row['bytes']
                and sha(path) == row['sha256'], 'The artifact bytes differ: ' + name)
    return directory


def upload(directory, token):
    directory = check_files(directory)
    preflight(token)
    uploaded = []
    for approved in PINS['assets']:
        release, existing = check_draft(token)
        name = approved['name']
        if name in existing:
            print('Verified existing asset: ' + name, flush=True)
            continue
        path = directory / name
        require(path.stat().st_size == approved['bytes'] and sha(path) == approved['sha256'],
                'A verified file changed before upload')
        url = ('https://uploads.github.com/repos/' + PINS['repository'] + '/releases/'
               + str(PINS['draft_id']) + '/assets?name=' + urllib.parse.quote(name, safe=''))
        upload_headers = dict(headers(token), **{'Content-Type': 'application/octet-stream',
                                               'Content-Length': str(approved['bytes'])})
        print('Uploading missing asset: ' + name, flush=True)
        try:
            with path.open('rb') as source:
                request = urllib.request.Request(url, data=source, headers=upload_headers, method='POST')
                with urllib.request.build_opener(NoRedirect()).open(request, timeout=120) as response:
                    require(response.status == 201, 'Unexpected upload status')
                    remote = json.load(response)
        except urllib.error.HTTPError as error:
            raise RuntimeError('Asset upload failed with HTTP ' + str(error.code)) from None
        except (OSError, TimeoutError):
            raise RuntimeError('Asset transfer failed; existing assets were preserved') from None
        require(remote['name'] == name and remote['state'] == 'uploaded'
                and remote['size'] == approved['bytes']
                and remote.get('digest') == 'sha256:' + approved['sha256'], 'Uploaded bytes differ')
        uploaded.append(name)
    release, existing = preflight(token)
    require(len(existing) == len(PINS['assets']), 'The reviewed draft asset set is incomplete')
    print(json.dumps({'passed': True, 'releaseId': PINS['draft_id'], 'draft': release['draft'],
                      'assets': len(existing), 'uploaded': uploaded, 'published': False}))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=('preflight', 'check-files', 'upload'))
    parser.add_argument('--directory', type=Path)
    args = parser.parse_args()
    try:
        if args.mode == 'check-files':
            require(args.directory is not None, 'A verified artifact directory is required')
            check_files(args.directory)
            print(json.dumps({'passed': True, 'verifiedFiles': len(PINS['assets'])}))
        else:
            token = os.environ.get('GH_TOKEN', '')
            require(re.fullmatch('[A-Za-z0-9_]+', token) is not None, 'The workflow token is missing')
            if args.mode == 'preflight':
                _, existing = preflight(token)
                print(json.dumps({'passed': True, 'draft': True, 'existingAssets': len(existing)}))
            else:
                require(args.directory is not None, 'A verified artifact directory is required')
                upload(args.directory, token)
    except Exception as error:
        print('Upload-only validation failed: ' + str(error), flush=True)
        raise SystemExit(1) from None
