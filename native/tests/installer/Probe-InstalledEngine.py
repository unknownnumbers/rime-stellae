"""Probe the installed engine using only the hosted runner's synthetic fixture."""
# SPDX-License-Identifier: GPL-3.0-only
import argparse
import ctypes as C
import json
import os
from pathlib import Path
import re

p = argparse.ArgumentParser()
p.add_argument('--engine', required=True)
p.add_argument('--header', required=True)
p.add_argument('--shared', required=True)
p.add_argument('--user', required=True)
p.add_argument('--report', required=True)
p.add_argument('--empty', action='store_true')
a = p.parse_args()
if os.environ.get('GITHUB_ACTIONS') != 'true':
    raise SystemExit('Use only a disposable hosted runner.')
body = Path(a.header).read_text(encoding='utf-8-sig').split('typedef struct RIME_FLAVORED(rime_api_t) {', 1)[1].split('} RIME_FLAVORED(RimeApi);', 1)[0]
body = re.sub(r'/\*.*?\*/|//[^\n]*', '', body, flags=re.S)
names = re.findall(r'\(\s*\*\s*(\w+)\s*\)', body)
class Api(C.Structure):
    _fields_ = [('data_size', C.c_int)] + [(n, C.c_void_p) for n in names]
class Traits(C.Structure):
    _fields_ = [('data_size', C.c_int)] + [(n, C.c_char_p) for n in ['shared_data_dir', 'user_data_dir', 'distribution_name', 'distribution_code_name', 'distribution_version', 'app_name']] + [('modules', C.c_void_p), ('min_log_level', C.c_int), ('log_dir', C.c_char_p), ('prebuilt_data_dir', C.c_char_p), ('staging_dir', C.c_char_p)]
class Status(C.Structure):
    _fields_ = [('data_size', C.c_int), ('schema_id', C.c_char_p), ('schema_name', C.c_char_p)] + [(n, C.c_int) for n in ['is_disabled', 'is_composing', 'is_ascii_mode', 'is_full_shape', 'is_simplified', 'is_traditional', 'is_ascii_punct']]
class Commit(C.Structure):
    _fields_ = [('data_size', C.c_int), ('text', C.c_char_p)]
report = {'passed': False, 'syntheticFixtureOnly': True, 'empty': a.empty, 'checks': [], 'physicalKeyboardTested': False}
def check(name, value):
    report['checks'].append({'name': name, 'passed': bool(value)})
    if not value:
        raise RuntimeError(name)
engine = Path(a.engine).resolve()
logs = Path(a.report).parent/'synthetic-engine-log'
logs.mkdir(parents=True, exist_ok=True)
initialized = False
session = 0
try:
    with os.add_dll_directory(str(engine.parent)):
        dll = C.CDLL(str(engine))
        dll.rime_get_api.restype = C.POINTER(Api)
        api = dll.rime_get_api().contents
        def call(name, result, parameters=()):
            return C.CFUNCTYPE(result, *parameters)(getattr(api, name))
        traits = Traits()
        traits.data_size = C.sizeof(traits)-C.sizeof(C.c_int)
        traits.shared_data_dir = str(Path(a.shared).resolve()).encode()
        traits.user_data_dir = str(Path(a.user).resolve()).encode()
        traits.distribution_name = b'Stellae public fixture'
        traits.distribution_code_name = b'RimeStellae'
        traits.distribution_version = b'0.17.4.61052'
        traits.app_name = b'rime.stellae.public_fixture'
        traits.log_dir = str(logs).encode()
        traits.prebuilt_data_dir = traits.shared_data_dir
        traits.staging_dir = str(Path(a.user).resolve()/'build').encode()
        call('setup', None, [C.POINTER(Traits)])(C.byref(traits))
        call('initialize', None, [C.c_void_p])(None)
        initialized = True
        session = call('create_session', C.c_size_t)()
        check('session-created', session != 0)
        status = Status()
        status.data_size = C.sizeof(status)-C.sizeof(C.c_int)
        check('status-available', call('get_status', C.c_int, [C.c_size_t, C.POINTER(Status)])(session, C.byref(status)))
        report['schema'] = status.schema_id.decode() if status.schema_id else None
        check('expected-schema', report['schema'] == ('.default' if a.empty else 'gui_test'))
        call('free_status', C.c_int, [C.POINTER(Status)])(C.byref(status))
        if a.empty:
            for key in [ord('a'), ord('z'), ord('0'), ord('9'), 0x20, 0xff0d, 0xff08, 0xff1b, 0xff09, 0xff51, 0xff53, 0xffc1]:
                check(f'empty-key-{key}-unhandled', not call('process_key', C.c_int, [C.c_size_t, C.c_int, C.c_int])(session, key, 0))
        else:
            for repeat in range(3):
                for key in b'abc':
                    check(f'fixture-{repeat}-{key}-handled', call('process_key', C.c_int, [C.c_size_t, C.c_int, C.c_int])(session, key, 0))
                check(f'fixture-{repeat}-space', call('process_key', C.c_int, [C.c_size_t, C.c_int, C.c_int])(session, 0x20, 0))
                commit = Commit()
                commit.data_size = C.sizeof(commit)-C.sizeof(C.c_int)
                check(f'fixture-{repeat}-commit', call('get_commit', C.c_int, [C.c_size_t, C.POINTER(Commit)])(session, C.byref(commit)))
                check(f'fixture-{repeat}-text', commit.text == b'cn01')
                call('free_commit', C.c_int, [C.POINTER(Commit)])(C.byref(commit))
        report['passed'] = True
except Exception as error:
    report['error'] = str(error)
finally:
    if session:
        call('destroy_session', C.c_int, [C.c_size_t])(session)
    if initialized:
        call('finalize', None)()
    Path(a.report).write_text(json.dumps(report, indent=2)+'\n', encoding='utf-8')
print(json.dumps(report, indent=2))
raise SystemExit(0 if report['passed'] else 1)
