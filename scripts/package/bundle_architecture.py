"""Resolve the bundle backend and application compatibility payload.

SPDX-License-Identifier: GPL-3.0-only
"""

ENGINES = {'x64': ('engine-n01', 'rime.dll'), 'x86': ('engine-r5', 'Win32/rime.dll')}
LEGACY_X86_BACKEND = ('Win32/StellaeServer.exe', 'Win32/StellaeDeployer.exe', 'Win32/rime.dll')


def client_architectures(inputs):
    clients = inputs.get('nativeFrontend', {}).get('clientOnlyArchitectures', [])
    if not isinstance(clients, list) or clients not in ([], ['x86']):
        raise ValueError('Only the x86 frontend may use the client-only build scope')
    return clients


def excluded_native_paths(inputs):
    # Manifests without the client-only declaration describe historical dual
    # runtime packages. Do not reinterpret their archived payload contracts.
    return set(LEGACY_X86_BACKEND) if client_architectures(inputs) else set()


def runtime_engines(inputs):
    specification = inputs.get('nativeEngines')
    if specification is None:
        return {}
    expected = {arch: value for arch, value in ENGINES.items()
                if not client_architectures(inputs) or arch == 'x64'}
    if specification != {arch: variant for arch, (variant, _) in expected.items()}:
        raise ValueError('The runtime engine declaration differs from the frontend architecture roles')
    return expected


def excluded_native_records(inputs, base_files):
    excluded = excluded_native_paths(inputs)
    records = [{'installed_path': row['path'], 'sha256': row['sha256'],
                'reason': 'x86 application clients use the x64 backend'}
               for row in base_files if row['path'] in excluded]
    if {row['installed_path'] for row in records} != excluded or len(records) != len(excluded):
        raise ValueError('The original package is missing a declared legacy backend image')
    return sorted(records, key=lambda row: row['installed_path'])
