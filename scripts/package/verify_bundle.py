"""Verify extracted payload bytes and the retained/rebuilt native image set."""
# SPDX-License-Identifier: GPL-3.0-only
import argparse
import hashlib
import json
from pathlib import Path
import re
from zipfile import ZipFile

from apply_frontend_overlays import ENGINES, MACHINES, frontend_products, image_machine
from prepare_bundle import DEFAULT_FONT_NAME, FONT_INSTALLER_HELPERS, check_scheme_archive


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load(path):
    return json.loads(path.read_text('utf-8-sig'))


def contained(root, relative):
    path = (root / relative).resolve()
    if not path.is_relative_to(root.resolve()) or not path.is_file():
        raise SystemExit('The package has an invalid file path')
    return path


p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--stage', type=Path, required=True)
p.add_argument('--extracted', type=Path, required=True)
p.add_argument('--report', type=Path, required=True)
p.add_argument('--engine-sources', type=Path)
a = p.parse_args()
files = [path for path in a.extracted.rglob('*') if path.is_file()]
hashes = {digest(path) for path in files}
manifest = load(a.stage / 'package-manifest.json')
shared = (a.stage / 'shared-payload/data').resolve()
profile = load(shared / 'config-source-manifest.json')
profile_records = profile['source_files'] + profile['generated_files']
for entry in profile_records:
    path = contained(shared, entry['path'])
    if path.stat().st_size != entry['bytes'] or digest(path) != entry['sha256']:
        raise SystemExit('Installed profile manifest describes stale bytes: ' + entry['path'])
snapshot = contained(a.stage, profile['archive_provenance']['original_manifest'])
if digest(snapshot) != profile['archive_provenance']['original_manifest_sha256']:
    raise SystemExit('Original scheme profile snapshot differs')
installed = {}
for entry in manifest['files']:
    path = contained(a.stage, entry['path'])
    if path.stat().st_size != entry['bytes'] or digest(path) != entry['sha256']:
        raise SystemExit('Staged package differs from its manifest: ' + entry['path'])
    if entry['sha256'] not in hashes:
        raise SystemExit('Completed installer is missing declared bytes: ' + entry['path'])
    if entry['installed_path'] in installed:
        raise SystemExit('Duplicate installed payload path')
    installed[entry['installed_path']] = entry
for name in ['package-manifest.json', 'package-license-index.json']:
    if digest(a.stage / name) not in hashes:
        raise SystemExit('Missing installed metadata: ' + name)
font_collection = None
if (a.stage/'font-payload/font-manifest.json').is_file():
    font_path = f'font-payload/{DEFAULT_FONT_NAME}'
    font_extensions = {'.otf', '.ttf', '.ttc', '.otc'}
    staged_fonts = [row['path'] for row in manifest['files'] if Path(row['path']).suffix.lower() in font_extensions]
    extracted_fonts = [path.name for path in files if path.suffix.lower() in font_extensions]
    if staged_fonts != [font_path] or extracted_fonts != [DEFAULT_FONT_NAME]:
        raise SystemExit('The installer must contain exactly one static Regular font collection.')
    required_font_files = {*FONT_INSTALLER_HELPERS, 'font-notices/font-manifest.json',
                           'font-notices/OFL.txt', 'font-notices/NOTICE.txt'}
    if not required_font_files.issubset(installed):
        raise SystemExit('The font collection installation helper or notices are missing.')
    legacy = {'fontprofile.ps1', 'fontprofilenative.cs', 'stellaefontprofile.exe'}
    if any(path.name.lower() in legacy for path in files):
        raise SystemExit('The installer contains a legacy standalone font tool.')
    font_collection = {'path': font_path, 'sha256': installed[font_path]['sha256']}
for path in files:
    if path.suffix.lower() in {'.pdb', '.dmp', '.log'} or '.userdb' in path.name:
        raise SystemExit('Unexpected runtime or diagnostic file')

provenance = load(a.stage / 'bundle-provenance.json')
inputs = load(a.stage / 'bundle-inputs.json')
base = load(a.stage / 'base-package-license-index.json')
licenses = {row['installed_path']: row for row in load(a.stage / 'package-license-index.json')['files']}
full_frontend = 'nativeFrontend' in inputs
overlay = load(a.stage / 'server-overlay-verification.json')
source_ref = manifest['sourceRef']
if inputs.get('schemes', {}).get('sourceDirectory') == 'schemes':
    archive_record = provenance['schemeArchive']
    archive = contained(a.stage, 'scheme-notices/' + archive_record['name'])
    if (archive_record['source_ref'] != source_ref or archive_record['source_prefix'] != 'schemes'
            or archive_record['sha256'] != digest(archive)
            or profile['archive_provenance']['source_ref'] != source_ref
            or profile['archive_provenance']['source_prefix'] != 'schemes'):
        raise SystemExit('The installed scheme and frontend do not share the same source commit')
    with ZipFile(archive) as source:
        check_scheme_archive(source, inputs, source_ref)
if font_collection:
    license_row = licenses[font_collection['path']]
    if (license_row['sha256'] != font_collection['sha256']
            or license_row['source_ids'] != ['candidate-font:regular']
            or license_row['license_record'] != {
                'terms': 'OFL-1.1', 'references': ['font-notices/OFL.txt', 'font-notices/NOTICE.txt']}):
        raise SystemExit('The Regular font collection license record differs.')
if (not re.fullmatch('[a-f0-9]{40}', source_ref)
        or not overlay['passed'] or overlay['sourceRef'] != source_ref
        or (not full_frontend and (not isinstance(overlay['runId'], int) or overlay['runId'] < 1))
        or provenance['bundleVersion'] != manifest['bundleVersion']
        or inputs['bundleVersion'] != manifest['bundleVersion']
        or inputs['frontendVersion'] != manifest['frontendVersion']):
    raise SystemExit('Native overlay source or package identity differs')

suffixes = {'.exe', '.dll', '.ime'}
base_images = {row['path']: row for row in base['files'] if Path(row['path']).suffix.lower() in suffixes}
native_rows = [row for row in provenance['files'] if Path(row['installed_path']).suffix.lower() in suffixes]
current = {}
for row in native_rows:
    if row['installed_path'] in current:
        raise SystemExit('Duplicate current native image provenance')
    current[row['installed_path']] = row
staged_images = {path.relative_to(a.stage).as_posix() for path in a.stage.rglob('*')
                 if path.is_file() and path.suffix.lower() in suffixes
                 and not path.relative_to(a.stage).as_posix().startswith('archives/')}
if len(base_images) != 14 or set(current) != set(base_images) or staged_images != set(base_images):
    raise SystemExit('The complete native image set differs')
expected = ({name: arch for arch, products in frontend_products(inputs['nativeFrontend']).items() for name in products}
            if full_frontend else {'StellaeServer.exe': 'x64', 'Win32/StellaeServer.exe': 'x86'})
specs = {} if full_frontend else inputs['serverOverlays']['architectures']
proof_rows = overlay['rebuiltImages' if full_frontend else 'rebuiltServers']
engine_rows = overlay.get('rebuiltRuntimeEngines', [])
engine_spec = inputs.get('nativeEngines')
expected_engines = {name: arch for arch, (_, name) in ENGINES.items()} if engine_spec else {}
unchanged = len(base_images) - len(expected) - len(expected_engines)
if (('nativeEngines' in inputs and
        (not full_frontend or engine_spec != {arch: variant for arch, (variant, _) in ENGINES.items()}))
        or (a.engine_sources is not None) != bool(expected_engines)
        or (not full_frontend and set(specs) != set(MACHINES))
        or len(proof_rows) != len(expected)
        or {row['installed_path'] for row in proof_rows} != set(expected)
        or len(engine_rows) != len(expected_engines)
        or {row['installed_path'] for row in engine_rows} != set(expected_engines)
        or overlay['nativeImages'] != len(base_images) or overlay['unchangedNativeImages'] != unchanged
        or overlay['runtimeEnginesPreserved'] is not (not expected_engines)):
    raise SystemExit('The rebuilt and retained native image sets differ')
proof = {row['installed_path']: row for row in proof_rows + engine_rows}
rebuilt = []
rebuilt_engines = []
engine_extractions = [path for path in files if re.fullmatch(r'rime(?:_\d+)?\.dll', path.name, re.IGNORECASE)]
if expected_engines and len(engine_extractions) != len(expected_engines):
    raise SystemExit('The extracted installer must contain exactly one runtime for each architecture')
for name, arch in (expected | expected_engines).items():
    row = current[name]
    machine = MACHINES[arch]
    engine = name in expected_engines
    kind = 'rebuiltRuntimeEngine' if engine else ('rebuiltFrontend' if full_frontend else 'rebuiltServer')
    label = 'runtime engine' if engine else ('frontend' if full_frontend else 'server')
    if engine:
        variant = ENGINES[arch][0]
        corresponding_source = f'{variant}-{arch}-source.zip'
    else:
        corresponding_source = 'bundle-project-source.zip' if full_frontend else f'server-{arch}-source.zip'
    if (row['source'] != kind or proof.get(name) != row
            or row['original_sha256'] != base_images[name]['sha256']
            or row['source_ref'] != source_ref or row['architecture'] != arch
            or row['corresponding_source'] != corresponding_source):
        raise SystemExit(f'Rebuilt {label} provenance differs: {name}')
    if not full_frontend:
        spec = specs[arch]
        if (spec['installedPath'] != name or spec['machine'] != machine or row['original_sha256'] != spec['baseSha256']
                or row['source_run'] != overlay['runId']
                or not re.fullmatch('[a-f0-9]{64}', row['assembled_source_sha256'])):
            raise SystemExit('Rebuilt server provenance differs: ' + name)
    path = contained(a.stage, name)
    if (digest(path) != row['sha256'] or installed[name]['sha256'] != row['sha256']
            or row['sha256'] not in hashes or image_machine(path) != machine):
        raise SystemExit('Rebuilt product differs: ' + name)
    license_row = licenses[name]
    if (license_row['sha256'] != row['sha256']
            or license_row['original_sha256'] != base_images[name]['sha256']
            or license_row['license_record'] != base_images[name]
            or not set(base_images[name].get('source_ids', [])).issubset(license_row['source_ids'])
            or 'project-code' not in license_row['source_ids']):
        raise SystemExit('Rebuilt image inherited notices differ: ' + name)
    rebuilt_row = {'path': name, 'sha256': row['sha256'], 'original_sha256': row['original_sha256'],
                   'sourceRef': source_ref}
    if not full_frontend:
        rebuilt_row['runId'] = row['source_run']
    if engine:
        archive = contained(a.engine_sources, corresponding_source)
        archive_sha = digest(archive)
        with ZipFile(archive) as source:
            source_index = json.loads(source.read('source-archive-manifest.json'))
        if (not re.fullmatch('[a-f0-9]{64}', row['native_manifest_sha256'])
                or row['variant'] != variant or row['corresponding_source_sha256'] != archive_sha
                or license_row['corresponding_source'] != corresponding_source
                or license_row['corresponding_source_sha256'] != archive_sha
                or license_row['native_manifest_sha256'] != row['native_manifest_sha256']
                or license_row['engine_variant'] != variant or source_index['variant'] != variant
                or {'publicBuildCommit', 'publicBuildRunId'}.intersection(source_index)
                or sum(digest(path) == row['sha256'] and image_machine(path) == machine
                       for path in engine_extractions) != 1):
            raise SystemExit('Extracted runtime or its corresponding source differs: ' + name)
        rebuilt_engines.append({
            **rebuilt_row, 'architecture': arch, 'variant': variant,
            'correspondingSource': corresponding_source, 'correspondingSourceSha256': archive_sha,
        })
    else:
        rebuilt.append(rebuilt_row)

retained = []
for name, row in current.items():
    if name in proof:
        continue
    if (row['source'] != 'frontendInstaller' or row['sha256'] != base_images[name]['sha256']
            or digest(contained(a.stage, name)) != row['sha256']
            or installed[name]['sha256'] != row['sha256'] or row['sha256'] not in hashes):
        raise SystemExit('Reused product differs: ' + name)
    retained.append({'path': name, 'sha256': row['sha256']})
if (len(retained) != unchanged or len(rebuilt) != len(expected)
        or len(rebuilt_engines) != len(expected_engines)):
    raise SystemExit('Native image verification is incomplete')

report = {'format': 'stellae-bundle-extraction-v1', 'passed': True,
          'bundleVersion': manifest['bundleVersion'], 'frontendVersion': manifest['frontendVersion'],
          'sourceRef': source_ref,
          'verifiedInputFiles': len(manifest['files']), 'installedProfileRecordsVerified': len(profile_records),
          'extractedFiles': len(files), 'reusedImages': retained, 'rebuiltImages': rebuilt,
          'nativeImages': len(current), 'physicalKeyboardTested': False}
if not full_frontend:
    report['sourceRunId'] = overlay['runId']
if rebuilt_engines:
    report['rebuiltRuntimeEngines'] = rebuilt_engines
if font_collection:
    report['candidateFontCollection'] = font_collection
a.report.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
print(json.dumps({'passed': True, 'verifiedInputFiles': len(manifest['files']),
                  'reusedImages': len(retained), 'rebuiltImages': len(rebuilt),
                  'rebuiltRuntimeEngines': len(rebuilt_engines)}))
