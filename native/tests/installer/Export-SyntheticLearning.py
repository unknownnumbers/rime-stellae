"""Export only the hosted fixture's learning records through the public levers API."""
# SPDX-License-Identifier: GPL-3.0-only
import argparse
import ctypes as C
import json
import os
from pathlib import Path
import re

p = argparse.ArgumentParser()
for name in ['engine', 'header', 'shared', 'user', 'output']:
    p.add_argument('--'+name, required=True)
a = p.parse_args()
if os.environ.get('GITHUB_ACTIONS') != 'true':
    raise SystemExit('Use a disposable hosted runner.')
def fields(file, name):
    s = Path(file).read_text(encoding='utf-8-sig').split('typedef struct RIME_FLAVORED('+name+') {', 1)[1].split('}', 1)[0]
    s = re.sub(r'/\*.*?\*/|//[^\n]*', '', s, flags=re.S)
    return [('data_size', C.c_int)]+[(n, C.c_void_p) for n in re.findall(r'\(\s*\*\s*(\w+)\s*\)', s)]
class Api(C.Structure):
    _fields_ = fields(a.header, 'rime_api_t')
class Levers(C.Structure):
    _fields_ = fields(Path(a.header).with_name('rime_levers_api.h'), 'rime_levers_api_t')
class Traits(C.Structure):
    _fields_ = [('data_size', C.c_int)] + [(n, C.c_char_p) for n in ['shared_data_dir', 'user_data_dir', 'distribution_name', 'distribution_code_name', 'distribution_version', 'app_name']] + [('modules', C.c_void_p), ('min_log_level', C.c_int), ('log_dir', C.c_char_p), ('prebuilt_data_dir', C.c_char_p), ('staging_dir', C.c_char_p)]
class Module(C.Structure):
    _fields_ = [('data_size', C.c_int), ('module_name', C.c_char_p), ('initialize', C.c_void_p), ('finalize', C.c_void_p), ('get_api', C.c_void_p)]
engine = Path(a.engine).resolve()
out = Path(a.output)
out.parent.mkdir(parents=True, exist_ok=True)
with os.add_dll_directory(str(engine.parent)):
    lib = C.CDLL(str(engine))
    lib.rime_get_api.restype = C.POINTER(Api)
    api = lib.rime_get_api().contents
    traits = Traits()
    traits.data_size = C.sizeof(traits)-C.sizeof(C.c_int)
    traits.shared_data_dir = str(Path(a.shared).resolve()).encode()
    traits.user_data_dir = str(Path(a.user).resolve()).encode()
    traits.app_name = b'rime.stellae.synthetic_export'
    traits.log_dir = str(out.parent).encode()
    C.CFUNCTYPE(None, C.POINTER(Traits))(api.setup)(C.byref(traits))
    C.CFUNCTYPE(None, C.c_void_p)(api.deployer_initialize)(None)
    try:
        module = C.CFUNCTYPE(C.POINTER(Module), C.c_char_p)(api.find_module)(b'levers')
        if not module:
            raise RuntimeError('Levers module unavailable.')
        levers = C.CFUNCTYPE(C.POINTER(Levers))(module.contents.get_api)().contents
        exported = C.CFUNCTYPE(C.c_int, C.c_char_p, C.c_char_p)(levers.export_user_dict)(b'b01_public_fixture', str(out.resolve()).encode())
        if exported <= 0:
            raise RuntimeError('No synthetic learning records were exported.')
        records = sorted(line for line in out.read_text(encoding='utf-8-sig').splitlines() if line and not line.startswith('#'))
        if not records:
            raise RuntimeError('Synthetic learning export has no records.')
        out.with_suffix('.json').write_text(json.dumps({'passed': True, 'syntheticFixtureOnly': True, 'exported': exported, 'records': records}, indent=2)+'\n', encoding='utf-8')
    finally:
        C.CFUNCTYPE(None)(api.finalize)()
