"""Replace frontend images and optional runtime engines using checked build artifacts."""
# SPDX-License-Identifier: GPL-3.0-only
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import shutil
import struct
from zipfile import ZIP_DEFLATED, ZipFile


PRODUCTS = {
    'x64': ('stellaex64.dll', 'stellaex64.ime', 'StellaeServer.exe'),
    'x86': ('stellae.dll', 'stellae.ime', 'Win32/StellaeServer.exe'),
}
MACHINES = {'x64': 0x8664, 'x86': 0x014c}
ENGINES = {'x64': ('engine-n01', 'rime.dll'), 'x86': ('engine-r5', 'Win32/rime.dll')}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load(path):
    return json.loads(path.read_text('utf-8-sig'))


def save(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


def image_machine(path):
    raw = path.read_bytes()
    if len(raw) < 64 or raw[:2] != b'MZ':
        raise ValueError(f'Invalid DOS header: {path.name}')
    offset = struct.unpack_from('<I', raw, 0x3c)[0]
    if offset + 6 > len(raw) or raw[offset:offset + 4] != b'PE\0\0':
        raise ValueError(f'Invalid PE header: {path.name}')
    return struct.unpack_from('<H', raw, offset + 4)[0]


def unique(root, name):
    files = list(root.rglob(name))
    if len(files) != 1 or not files[0].is_file() or files[0].is_symlink():
        raise ValueError(f'Expected exactly one native input: {root.name}/{name}')
    return files[0]


def checked_products(product_root, source_root, arch, version, source_files):
    record_path = unique(product_root, 'build-result.json')
    record = load(record_path)
    output = record_path.parent
    if (not record['passed'] or record['architecture'] != arch
            or record['sourceVersion'] != version or record['symbolsBundled']
            or record['engineBundled'] or record['engineRebuilt']
            or record['optInNumericTraceCompiled']):
        raise ValueError(f'Native artifact validation differs: {arch}')
    archive = unique(source_root, 'candidate-source.zip')
    if digest(archive) != record['candidateSourceArchiveSha256']:
        raise ValueError(f'Native source archive bytes differ: {arch}')
    with ZipFile(archive) as source:
        for name, expected in source_files.items():
            if hashlib.sha256(source.read(name)).hexdigest() != expected:
                raise ValueError(f'Corresponding native source differs: {arch}/{name}')
    checked = {}
    for product in record['products']:
        name = product['installedRelativePath']
        if name not in PRODUCTS[arch] or name in checked:
            raise ValueError(f'Unexpected native installed path: {name}')
        path = output / Path(name).name
        if (product['version'] != version or product['machine'] != MACHINES[arch]
                or path.stat().st_size != product['bytes'] or digest(path) != product['sha256']
                or image_machine(path) != MACHINES[arch]):
            raise ValueError(f'Native product bytes differ: {arch}/{name}')
        checked[name] = path, product['sha256']
    if set(checked) != set(PRODUCTS[arch]):
        raise ValueError(f'Incomplete native artifact: {arch}')
    return checked


def check_notices(artifact, repository):
    notices = repository / 'licenses'
    files = [path for path in notices.rglob('*') if path.is_file()]
    if not files:
        raise ValueError('The pinned engine build notices are missing')
    for notice in (*files, repository / 'LICENSE'):
        original = artifact / notice.relative_to(repository)
        if not original.is_file() or digest(original) != digest(notice):
            raise ValueError(f'The engine build omitted or changed a notice: {notice.name}')


def check_source_archive(artifact, record, manifest, variant, destination):
    zip_path = artifact / 'assembled-source.zip'
    assembly_path = artifact / 'native-source-assembly.json'
    assembly = load(assembly_path)
    specification = manifest['variants'][variant]
    pinned_sources = [{'path': '.', 'source': specification['rootSource']}]
    pinned_sources.extend({'path': item['path'], 'source': item['source']} for item in manifest['enginePlugins'])
    for item in pinned_sources:
        item['commit'] = manifest['sources'][item['source']]['commit']
    patches = {row['id']: row for row in manifest['patches']}
    pinned_patches = [{key: patches[component['patch']][key] for key in ('path', 'sha256')}
                      for component in specification['components']]
    if (assembly['schema'] != 'stellae-native-assembly/1' or assembly['variant'] != variant
            or assembly['sourceAssemblyPassed'] is not True or assembly['sources'] != pinned_sources
            or assembly['patches'] != pinned_patches or digest(zip_path) != record['assembledSourceSha256']):
        raise ValueError(f'Engine source assembly differs from the pinned source: {variant}')

    with ZipFile(zip_path) as original:
        files = original.namelist()
        archived = json.loads(original.read('source-archive-manifest.json').decode('utf-8-sig'))
        entries = archived['files']
        names = [entry['path'] for entry in entries]
        if (archived['schema'] != 'stellae-assembled-source/1' or archived['variant'] != variant
                or archived['capturedBeforeCompilation'] is not True or archived['gitMetadataIncluded'] is not False
                or archived['sources'] != pinned_sources or len(entries) != record['assembledSourceFiles']
                or len(set(names)) != len(names) or len(set(files)) != len(files)
                or set(files) != {'source-archive-manifest.json', *names}
                or original.read('native-source-assembly.json') != assembly_path.read_bytes()):
            raise ValueError(f'Engine corresponding source inventory differs: {variant}')
        archive_members = {}
        for entry in entries:
            name = entry['path']
            parts = PurePosixPath(name).parts
            if (not parts or name != PurePosixPath(name).as_posix() or
                    ':' in name or '\\' in name or '..' in parts or '.git' in parts or name.startswith('/')):
                raise ValueError(f'Unexpected engine source archive path: {name}')
            raw = original.read(name)
            if len(raw) != entry['bytes'] or hashlib.sha256(raw).hexdigest() != entry['sha256']:
                raise ValueError(f'Engine source archive member differs: {name}')
            archive_members[name] = raw
        # Upstream source files and notices stay byte-for-byte. Only the generated
        # index is rewritten so private runner identifiers never leave CI.
        safe_index = {key: archived[key] for key in (
            'schema', 'variant', 'capturedBeforeCompilation', 'sources', 'files',
            'excludedPrebuiltFiles', 'gitMetadataIncluded'
        )}
        with ZipFile(destination, 'x', ZIP_DEFLATED) as public:
            for name, raw in archive_members.items():
                public.writestr(name, raw)
            public.writestr('source-archive-manifest.json', json.dumps(safe_index, indent=2) + '\n')


def checked_engine(artifact, arch, variant, native_manifest, engine_sources, previous_build=None):
    record = load(artifact / 'build-result.json')
    manifest = load(native_manifest)
    manifest_sha = record['manifestSha256']
    image = artifact / 'dist/lib/rime.dll'
    current_build = manifest_sha == digest(native_manifest)
    previous_manifest = artifact / 'build-source/native/source-manifest.json'
    reviewed_build = (previous_build is not None
                      and manifest_sha == previous_build['manifestSha256']
                      and record['sha256'] == previous_build['runtimeSha256'][arch]
                      and previous_manifest.is_file() and digest(previous_manifest) == manifest_sha)
    if (record['schema'] != 'stellae-native-build/1' or record['variant'] != variant
            or record['architecture'] != arch or not (current_build or reviewed_build)
            or record['compilationPassed'] is not True or record['upstreamCTestPassed'] is not True
            or record['peMetadataVerified'] is not True or record['symbolsBundled'] is not False
            or record['preeditHelperChecks'] != 34 or digest(image) != record['sha256']
            or image_machine(image) != MACHINES[arch]):
        raise ValueError(f'Engine build or architecture proof differs: {arch}')
    check_notices(artifact, native_manifest.resolve().parents[1])
    source = engine_sources / f'{variant}-{arch}-source.zip'
    check_source_archive(artifact, record, manifest, variant, source)
    return image, {
        'variant': variant, 'native_manifest_sha256': manifest_sha,
        'corresponding_source': source.name, 'corresponding_source_sha256': digest(source),
    }


def apply(stage, products, sources, source_ref, engines=None, native_manifest=None, engine_sources=None):
    if not re.fullmatch('[a-f0-9]{40}', source_ref):
        raise ValueError('Use the exact frontend source revision')
    inputs = load(stage / 'bundle-inputs.json')
    engine_spec = inputs.get('nativeEngines')
    previous_build = inputs.get('previousRuntimeBuild')
    if previous_build is not None and (
            engine_spec is None or set(previous_build['runtimeSha256']) != set(ENGINES)
            or any(not re.fullmatch('[a-f0-9]{64}', sha) for sha in
                   (previous_build['manifestSha256'], *previous_build['runtimeSha256'].values()))):
        raise ValueError('Previously built runtime hashes must be pinned for both architectures')
    expected_engine_spec = {arch: variant for arch, (variant, _) in ENGINES.items()}
    if (('nativeEngines' in inputs and engine_spec != expected_engine_spec)
            or (engine_spec is None and any(value is not None for value in (engines, native_manifest, engine_sources)))
            or (engine_spec is not None and any(value is None for value in (engines, native_manifest, engine_sources)))):
        raise ValueError('Runtime engine artifacts and the exact nativeEngines declaration are required together')
    source_files = inputs['nativeFrontend']['sourceFiles']
    if not source_files or any(not re.fullmatch('[a-f0-9]{64}', sha) for sha in source_files.values()):
        raise ValueError('Pin the frontend source changes')
    provenance_path = stage / 'bundle-provenance.json'
    provenance = load(provenance_path)
    base = load(stage / 'base-package-license-index.json')
    base_images = {row['path']: row['sha256'] for row in base['files']
                   if Path(row['path']).suffix.lower() in {'.exe', '.dll', '.ime'}}
    staged = {path.relative_to(stage).as_posix(): digest(path)
              for path in stage.rglob('*') if path.is_file()
              and path.suffix.lower() in {'.exe', '.dll', '.ime'}}
    if staged != base_images:
        raise ValueError('The original native image set differs')
    changes = []
    engine_changes = []
    expected = dict(base_images)

    def replace(name, path, arch, kind, source):
        sha = digest(path)
        old_sha = base_images[name]
        previous = [index for index, row in enumerate(provenance['files'])
                    if row['installed_path'] == name]
        if (len(previous) != 1 or sha == old_sha
                or provenance['files'][previous[0]]['sha256'] != old_sha):
            raise ValueError(f'The original native provenance differs: {name}')
        replacement = {
            'installed_path': name, 'source': kind, 'sha256': sha,
            'original_sha256': old_sha, 'source_ref': source_ref, 'architecture': arch,
            'generated_source_ids': ['project-code'], **source,
        }
        shutil.copyfile(path, stage / name)
        expected[name] = sha
        provenance['files'][previous[0]] = replacement
        return replacement

    engine_inputs = {}
    if engine_spec:
        engine_sources.mkdir()
        for arch, (variant, name) in ENGINES.items():
            path, details = checked_engine(engines / arch, arch, variant, native_manifest,
                                           engine_sources, previous_build)
            engine_inputs[arch] = (name, path, details)
    for arch in PRODUCTS:
        for name, (path, _) in checked_products(products / arch, sources / arch,
                                                 arch, inputs['frontendVersion'], source_files).items():
            changes.append(replace(name, path, arch, 'rebuiltFrontend', {
                'corresponding_source': 'bundle-project-source.zip',
                'transformation': 'rebuild the frontend from the pinned sources and patch',
            }))
    for arch, (name, path, details) in engine_inputs.items():
        engine_changes.append(replace(name, path, arch, 'rebuiltRuntimeEngine', {
            'transformation': 'rebuild the runtime engine from the pinned sources and patch',
            **details,
        }))
    for name, sha in expected.items():
        if digest(stage / name) != sha:
            raise ValueError(f'Native replacement does not match the reviewed set: {name}')
    save(provenance_path, provenance)
    result = {'passed': True, 'sourceRef': source_ref, 'rebuiltImages': changes,
              'nativeImages': len(base_images),
              'unchangedNativeImages': len(base_images) - len(changes) - len(engine_changes),
              'runtimeEnginesPreserved': not engine_changes}
    if engine_changes:
        result['rebuiltRuntimeEngines'] = engine_changes
    save(stage / 'server-overlay-verification.json', result)
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--stage', type=Path, required=True)
    parser.add_argument('--products', type=Path, required=True)
    parser.add_argument('--sources', type=Path, required=True)
    parser.add_argument('--source-ref', required=True)
    parser.add_argument('--engines', type=Path)
    parser.add_argument('--native-manifest', type=Path)
    parser.add_argument('--engine-sources', type=Path)
    args = parser.parse_args()
    print(json.dumps(apply(args.stage, args.products, args.sources, args.source_ref,
                           args.engines, args.native_manifest, args.engine_sources)))
