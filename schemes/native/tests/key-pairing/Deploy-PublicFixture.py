"""Explicit public C API deployment, numeric results and full compiler logs."""
from pathlib import Path
import argparse
import ctypes as C
import json
import os
import re

parser = argparse.ArgumentParser()
parser.add_argument('--engine', required=True)
parser.add_argument('--header', required=True)
parser.add_argument('--shared', required=True)
parser.add_argument('--user', required=True)
parser.add_argument('--logs', required=True)
parser.add_argument('--report', required=True)
args = parser.parse_args()
engine, shared, user, logs = [Path(value).resolve() for value in
    [args.engine, args.shared, args.user, args.logs]]
logs.mkdir(parents=True, exist_ok=True)
report = dict(PublicFixtureOnly=True, Engine=str(engine), Shared=str(shared),
    User=str(user), Logs=str(logs), UiDeployerUsed=False,
    WorkspaceDeployReturned=None, ExplicitSchemaDeployReturned=None,
    WeaselConfigDeployReturned=None, CompiledSchemaList=[], RequiredFiles={},
    DeploymentPassed=False, Error=None)
header = Path(args.header).read_text(encoding='utf-8-sig')
body = header.split('typedef struct RIME_FLAVORED(rime_api_t) {', 1)[1].split('} RIME_FLAVORED(RimeApi);', 1)[0]
body = re.sub(r'/\*.*?\*/|//[^\n]*', '', body, flags=re.S)
names = re.findall(r'\(\s*\*\s*(\w+)\s*\)', body)
class Api(C.Structure):
    _fields_ = [('data_size', C.c_int)] + [(name, C.c_void_p) for name in names]
class Traits(C.Structure):
    _fields_ = [('data_size', C.c_int), ('shared_data_dir', C.c_char_p),
        ('user_data_dir', C.c_char_p), ('distribution_name', C.c_char_p),
        ('distribution_code_name', C.c_char_p), ('distribution_version', C.c_char_p),
        ('app_name', C.c_char_p), ('modules', C.POINTER(C.c_char_p)),
        ('min_log_level', C.c_int), ('log_dir', C.c_char_p),
        ('prebuilt_data_dir', C.c_char_p), ('staging_dir', C.c_char_p)]
class Config(C.Structure):
    _fields_ = [('ptr', C.c_void_p)]
initialized = False
try:
    with os.add_dll_directory(str(engine.parent)):
        dll = C.CDLL(str(engine))
        dll.rime_get_api.restype = C.POINTER(Api)
        api = dll.rime_get_api().contents
        traits = Traits()
        traits.data_size = C.sizeof(Traits) - C.sizeof(C.c_int)
        traits.shared_data_dir = str(shared).encode()
        traits.user_data_dir = str(user).encode()
        traits.distribution_name = b'Public native fixture'
        traits.distribution_code_name = b'weasel'
        traits.distribution_version = b'0.17.4'
        traits.app_name = b'rime.public_native_fixture'
        traits.log_dir = str(logs).encode()
        traits.prebuilt_data_dir = str(shared).encode()
        traits.staging_dir = str(user / 'build').encode()
        C.CFUNCTYPE(None, C.POINTER(Traits))(api.setup)(C.byref(traits))
        C.CFUNCTYPE(None, C.c_void_p)(api.deployer_initialize)(None)
        initialized = True
        report['WorkspaceDeployReturned'] = bool(C.CFUNCTYPE(C.c_int)(api.deploy)())
        report['ExplicitSchemaDeployReturned'] = bool(C.CFUNCTYPE(C.c_int, C.c_char_p)(api.deploy_schema)(
            str(user / 'gui_test.schema.yaml').encode()))
        report['WeaselConfigDeployReturned'] = bool(C.CFUNCTYPE(C.c_int, C.c_char_p, C.c_char_p)(
            api.deploy_config_file)(b'weasel.yaml', b'config_version'))
        config = Config()
        opened = bool(C.CFUNCTYPE(C.c_int, C.c_char_p, C.POINTER(Config))(api.config_open)(b'default', C.byref(config)))
        report['CompiledDefaultOpened'] = opened
        if opened:
            try:
                count = C.CFUNCTYPE(C.c_size_t, C.POINTER(Config), C.c_char_p)(api.config_list_size)(C.byref(config), b'schema_list')
                for index in range(count):
                    value = C.create_string_buffer(256)
                    ok = C.CFUNCTYPE(C.c_int, C.POINTER(Config), C.c_char_p, C.c_char_p, C.c_size_t)(
                        api.config_get_string)(C.byref(config), f'schema_list/@{index}/schema'.encode(), value, len(value))
                    report['CompiledSchemaList'].append(value.value.decode() if ok else None)
            finally:
                C.CFUNCTYPE(C.c_int, C.POINTER(Config))(api.config_close)(C.byref(config))
        required = ['build/gui_test.schema.yaml', 'build/default.yaml', 'build/weasel.yaml',
            'build/b01_public_fixture.table.bin', 'build/b01_public_fixture.prism.bin',
            'build/b01_public_fixture.reverse.bin']
        report['RequiredFiles'] = {name: (user / name).is_file() for name in required}
        report['DeploymentPassed'] = all(report[key] for key in [
            'WorkspaceDeployReturned', 'ExplicitSchemaDeployReturned', 'WeaselConfigDeployReturned']) and \
            report['CompiledSchemaList'] == ['gui_test'] and all(report['RequiredFiles'].values())
except Exception as error:
    report['Error'] = str(error)
finally:
    if initialized:
        C.CFUNCTYPE(None)(api.finalize)()
    Path(args.report).write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
print(json.dumps(report, indent=2))
raise SystemExit(0 if report['DeploymentPassed'] else 1)
