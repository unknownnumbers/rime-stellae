"""Stage a verified x64 settings component without rebuilding the input engine.

SPDX-License-Identifier: GPL-3.0-only
"""
from pathlib import Path
import argparse, hashlib, json, os, re, shutil, struct, subprocess, zipfile

ROOT = Path(__file__).resolve().parents[2]
THEMES = ('reference_gray', 'stellae_sakura', 'stellae_lavender',
          'stellae_night', 'stellae_crimson', 'stellae_mono')


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--build-directory', type=Path, required=True)
    p.add_argument('--source-ref', required=True)
    p.add_argument('--output', type=Path, required=True)
    a = p.parse_args()
    assert re.fullmatch('[0-9a-f]{40}', a.source_ref), 'Use an exact source commit'
    record = json.loads((a.build_directory / 'build-result.json').read_text('utf-8-sig'))
    assert record['passed'] and record['architecture'] == 'x64'
    assert record['buildScope'] == 'settings-component' and len(record['products']) == 1
    assert not record['engineBundled'] and not record['engineRebuilt']
    product = record['products'][0]
    assert product['installedRelativePath'] == 'StellaeDeployer.exe' and product['machine'] == 0x8664
    image = a.build_directory / 'StellaeDeployer.exe'
    assert digest(image) == product['sha256'] and image.stat().st_size == product['bytes']
    raw = image.read_bytes()
    pe = struct.unpack_from('<I', raw, 0x3c)[0]
    assert raw[:2] == b'MZ' and raw[pe:pe+4] == b'PE\0\0'
    assert struct.unpack_from('<H', raw, pe+4)[0] == 0x8664

    def source(relative):
        flags = {'creationflags': subprocess.CREATE_NO_WINDOW} if os.name == 'nt' else {}
        raw = subprocess.run(['git', '-C', str(ROOT), 'show', a.source_ref + ':' + relative],
                             capture_output=True, check=True, **flags).stdout
        assert (ROOT / relative).read_bytes() == raw, 'Working input differs: ' + relative
        return raw

    inventory = json.loads(source('native/frontend-source-files.json'))
    archive = a.build_directory / 'candidate-source.zip'
    assert digest(archive) == record['candidateSourceArchiveSha256']
    with zipfile.ZipFile(archive) as z:
        for row in inventory['files']:
            if row.get('deleted'):
                assert row['path'] not in z.namelist()
            else:
                assert hashlib.sha256(z.read(row['path'])).hexdigest() == row['sha256']

    baseline = json.loads(source('installer/settings-update-baseline.json'))
    assert baseline['format'] == 'stellae-settings-baseline-v1'
    previous = {r['path']: r['sha256'] for r in baseline['files']}
    updater = source('scripts/package/Update-Settings.ps1')
    inputs = json.loads(source('installer/bundle-inputs.json'))
    out = a.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    rows = []

    def add(relative, data):
        path = out / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        rows.append({'path': relative, 'bytes': len(data),
                     'sha256': hashlib.sha256(data).hexdigest(),
                     'previousSha256': [previous[relative]] if relative in previous else []})

    add('StellaeDeployer.exe', raw)
    add('data/stellae_bundle_weasel.yaml', source('schemes/config/pc/weasel.custom.yaml'))
    names = ['color_scheme_' + t + '.png' for t in THEMES]
    names += ['candidate_font' + s + '.png' for s in ('', '_default', '_sc', '_tc', '_hk')]
    for name in names:
        add('data/preview/' + name, source('schemes/config/pc/preview/' + name))
    retired = [{'path': 'data/preview/color_scheme_reference_gray_' + suffix + '.png',
                'sha256': previous['data/preview/color_scheme_reference_gray_' + suffix + '.png']}
               for suffix in ('default', 'sc', 'tc', 'hk')]
    manifest = {'format': 'stellae-settings-update-v1', 'componentVersion': inputs['bundleVersion'],
                'sourceRef': a.source_ref, 'baselineSourceRef': baseline['sourceRef'],
                'updaterSha256': hashlib.sha256(updater).hexdigest(),
                'buildWorkflowSourceRef': os.environ.get('GITHUB_SHA'),
                'candidateSourceArchiveSha256': digest(archive),
                'files': rows, 'retiredPreviewFiles': retired}
    (out / 'settings-update-inputs.json').write_text(json.dumps(manifest, indent=2) + '\n',
                                                   encoding='utf-8', newline='\n')
    (out / 'Update-Settings.ps1').write_bytes(updater)
    shutil.copyfile(archive, out / 'candidate-source.zip')
    shutil.copyfile(a.build_directory / 'build-result.json', out / 'build-result.json')
    shutil.copyfile(ROOT / 'LICENSE', out / 'LICENSE')
    shutil.copytree(ROOT / 'licenses', out / 'licenses')
    print(json.dumps({'passed': True, 'sourceRef': a.source_ref, 'architecture': 'x64',
                      'files': len(rows), 'deployerSha256': product['sha256'],
                      'engineIncluded': False, 'inputDllsIncluded': False}))


if __name__ == '__main__':
    main()
