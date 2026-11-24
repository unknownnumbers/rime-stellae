"""Verify native dictionary labels and snapshot identity with hosted-only fixtures."""

# SPDX-License-Identifier: GPL-3.0-only
import argparse
import ctypes as c
from ctypes import wintypes as w
import json
import os
from pathlib import Path
import re
import subprocess
import time
import winreg


FIXTURES = [
    ('luna_pinyin', 'Active: cn_stellae', 'fixturecn'),
    ('pc_english', 'Active: en_intelligence', 'fixtureen'),
    ('jp_family', 'Active: jp_kanji', 'fixturejp'),
    ('jp_sela_custom', 'History: jp_romaji', 'fixturekana'),
    ('pc_mixed', 'History: pc_mixed', 'fixturemixed'),
    ('terra_pinyin', 'Other: terra_pinyin', 'fixtureother'),
]
LIST, DESCRIPTION, BACKUP, EXPORT, IMPORT = 1007, 1012, 1008, 1010, 1011
WM_COMMAND, WM_CLOSE = 0x0111, 0x0010
WM_GETTEXT, WM_GETTEXTLENGTH = 0x000D, 0x000E
LB_GETCOUNT, LB_GETTEXT, LB_GETTEXTLEN, LB_SETCURSEL = 0x018B, 0x0189, 0x018A, 0x0186


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def api_fields(file, name):
    text = Path(file).read_text(encoding='utf-8-sig')
    body = text.split('typedef struct RIME_FLAVORED(' + name + ') {', 1)[1].split('}', 1)[0]
    body = re.sub(r'/\*.*?\*/|//[^\n]*', '', body, flags=re.S)
    return [('data_size', c.c_int)] + [
        (name, c.c_void_p) for name in re.findall(r'\(\s*\*\s*(\w+)\s*\)', body)
    ]


def seed_learning(engine, header, shared, user):
    # Use a normal pre-existing installation record, as a deployed profile has.
    # Older engines otherwise leave the first-ever sync path relative to cwd.
    (user / 'installation.yaml').write_text(
        'installation_id: stellae-dictionary-fixture\nsync_dir: ' +
        json.dumps(str(user / 'sync')) + '\n', encoding='utf-8')

    class Api(c.Structure):
        _fields_ = api_fields(header, 'rime_api_t')

    class Levers(c.Structure):
        _fields_ = api_fields(header.with_name('rime_levers_api.h'), 'rime_levers_api_t')

    class Traits(c.Structure):
        _fields_ = [('data_size', c.c_int)] + [
            (name, c.c_char_p) for name in [
                'shared_data_dir', 'user_data_dir', 'distribution_name',
                'distribution_code_name', 'distribution_version', 'app_name',
            ]
        ] + [
            ('modules', c.c_void_p), ('min_log_level', c.c_int), ('log_dir', c.c_char_p),
            ('prebuilt_data_dir', c.c_char_p), ('staging_dir', c.c_char_p),
        ]

    class Module(c.Structure):
        _fields_ = [
            ('data_size', c.c_int), ('module_name', c.c_char_p),
            ('initialize', c.c_void_p), ('finalize', c.c_void_p), ('get_api', c.c_void_p),
        ]

    with os.add_dll_directory(str(engine.parent)):
        library = c.CDLL(str(engine))
        library.rime_get_api.restype = c.POINTER(Api)
        api = library.rime_get_api().contents
        traits = Traits()
        traits.data_size = c.sizeof(traits) - c.sizeof(c.c_int)
        traits.shared_data_dir, traits.user_data_dir = str(shared).encode(), str(user).encode()
        traits.app_name = b'rime.stellae.dictionary_fixture'
        traits.log_dir = str(user).encode()
        c.CFUNCTYPE(None, c.POINTER(Traits))(api.setup)(c.byref(traits))
        c.CFUNCTYPE(None, c.c_void_p)(api.deployer_initialize)(None)
        try:
            require(c.CFUNCTYPE(c.c_int, c.c_char_p)(api.run_task)(b'installation_update'),
                    'Could not initialize the synthetic installation')
            sync_buffer = c.create_string_buffer(4096)
            c.CFUNCTYPE(None, c.c_void_p, c.c_size_t)(api.get_user_data_sync_dir)(
                sync_buffer, len(sync_buffer))
            sync = Path(sync_buffer.value.decode()).resolve()
            require(sync.is_relative_to(user), 'Synthetic snapshots escaped the fixture directory')
            sync.mkdir(parents=True, exist_ok=True)
            module = c.CFUNCTYPE(c.POINTER(Module), c.c_char_p)(api.find_module)(b'levers')
            require(module, 'The fixture engine has no levers API')
            levers = c.CFUNCTYPE(c.POINTER(Levers))(module.contents.get_api)().contents
            import_table = c.CFUNCTYPE(c.c_int, c.c_char_p, c.c_char_p)(levers.import_user_dict)
            for dictionary, _, marker in FIXTURES:
                table = user / (dictionary + '-fixture.tsv')
                table.write_text(marker + '\tfixture\t1\n', encoding='utf-8')
                require(import_table(dictionary.encode(), str(table).encode()) > 0,
                        'Could not create synthetic learning database ' + dictionary)
                table.unlink()
        finally:
            c.CFUNCTYPE(None)(api.finalize)()


class DictionaryWindow:
    def __init__(self, process):
        self.process = process
        user = c.WinDLL('user32', use_last_error=True)

        def bind(name, result, *arguments):
            function = getattr(user, name)
            function.restype, function.argtypes = result, arguments
            return function

        self.callback = c.WINFUNCTYPE(w.BOOL, w.HWND, w.LPARAM)
        self.enum = bind('EnumWindows', w.BOOL, self.callback, w.LPARAM)
        self.owner = bind('GetWindowThreadProcessId', w.DWORD, w.HWND, c.POINTER(w.DWORD))
        self.visible = bind('IsWindowVisible', w.BOOL, w.HWND)
        self.enabled = bind('IsWindowEnabled', w.BOOL, w.HWND)
        self.child = bind('GetDlgItem', w.HWND, w.HWND, c.c_int)
        self.message = bind('SendMessageTimeoutW', w.LPARAM, w.HWND, w.UINT,
                            w.WPARAM, w.LPARAM, w.UINT, w.UINT, c.POINTER(c.c_size_t))
        self.window = self.wait_for_window()
        self.list = self.child(self.window, LIST)
        self.description = self.child(self.window, DESCRIPTION)
        require(self.description and self.visible(self.description),
                'The native dictionary purpose description is missing')

    def send(self, window, message, parameter=0, pointer=0):
        result = c.c_size_t()
        if not self.message(window, message, parameter, pointer, 2, 5000, c.byref(result)):
            raise c.WinError(c.get_last_error())
        return c.c_ssize_t(result.value).value

    def wait_for_window(self):
        matches = []

        @self.callback
        def find(window, _):
            pid = w.DWORD()
            self.owner(window, c.byref(pid))
            if pid.value == self.process.pid and self.visible(window) and self.child(window, LIST):
                matches.append(window)
            return True

        until = time.monotonic() + 30
        while time.monotonic() < until:
            require(self.process.poll() is None, 'The native dictionary process exited early')
            self.enum(find, 0)
            if matches:
                require(len(matches) == 1, 'Multiple native dictionary windows appeared')
                return matches[0]
            time.sleep(0.05)
        raise AssertionError('The native dictionary manager did not appear')

    def items(self):
        count = self.send(self.list, LB_GETCOUNT)
        require(count == len(FIXTURES), 'Unexpected synthetic dictionary count')
        items = []
        for index in range(count):
            length = self.send(self.list, LB_GETTEXTLEN, index)
            require(0 < length < 256, 'Invalid dictionary display label')
            text = c.create_unicode_buffer(length + 1)
            require(self.send(self.list, LB_GETTEXT, index, c.addressof(text)) == length,
                    'Could not read the native dictionary label')
            items.append(text.value)
        return items

    def select(self, index, dictionary):
        require(self.send(self.list, LB_SETCURSEL, index) == index,
                'Could not select the synthetic dictionary')
        self.send(self.window, WM_COMMAND, LIST | (1 << 16), self.list)
        length = self.send(self.description, WM_GETTEXTLENGTH)
        text = c.create_unicode_buffer(length + 1)
        self.send(self.description, WM_GETTEXT, length + 1, c.addressof(text))
        require('Storage ID: ' + dictionary in text.value and '\r\n' in text.value,
                'The description did not retain the original storage ID')
        require(all(self.enabled(self.child(self.window, control)) for control in [BACKUP, EXPORT, IMPORT]),
                'A native dictionary operation remained disabled after selection')
        return text.value


def main():
    parser = argparse.ArgumentParser()
    for name in ['engine', 'header', 'shared', 'user', 'deployer', 'report']:
        parser.add_argument('--' + name, required=True)
    args = parser.parse_args()
    require(os.environ.get('GITHUB_ACTIONS') == 'true' and
            os.environ.get('RUNNER_ENVIRONMENT') == 'github-hosted',
            'This UI probe requires a disposable GitHub-hosted Windows runner')
    runner = Path(os.environ['RUNNER_TEMP']).resolve()
    user = Path(args.user).resolve()
    require(user != runner and user.is_relative_to(runner) and not user.exists(),
            'The fixture user directory must be new and within RUNNER_TEMP')
    user.mkdir(parents=True)
    deployer = Path(args.deployer).resolve(strict=True)
    seed_learning(Path(args.engine).resolve(strict=True), Path(args.header).resolve(strict=True),
                  Path(args.shared).resolve(strict=True), user)
    registry = r'Software\RimeStellae'
    original = {}
    with winreg.CreateKey(winreg.HKEY_CURRENT_USER, registry) as key:
        for name in ['RimeUserDir', 'Language']:
            try:
                original[name] = winreg.QueryValueEx(key, name)
            except FileNotFoundError:
                original[name] = None
        try:
            winreg.SetValueEx(key, 'RimeUserDir', 0, winreg.REG_SZ, str(user))
            winreg.SetValueEx(key, 'Language', 0, winreg.REG_SZ, 'eng')
            with subprocess.Popen([str(deployer), '/dict'], cwd=deployer.parent,
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) as process:
                try:
                    dialog = DictionaryWindow(process)
                    labels = dialog.items()
                    require(labels == [label for _, label, _ in FIXTURES],
                            'The native dictionary aliases or categories differ')
                    results = []
                    for index, (dictionary, label, marker) in enumerate(FIXTURES):
                        description = dialog.select(index, dictionary)
                        dialog.send(dialog.window, WM_COMMAND, BACKUP,
                                    dialog.child(dialog.window, BACKUP))
                        until = time.monotonic() + 10
                        snapshots = []
                        while time.monotonic() < until:
                            snapshots = list(user.rglob(dictionary + '.userdb.txt'))
                            if snapshots:
                                break
                            time.sleep(0.05)
                        require(len(snapshots) == 1 and
                                marker in snapshots[0].read_text(encoding='utf-8-sig'),
                                'Snapshot operation used the display alias instead of the storage ID')
                        results.append({'storageId': dictionary, 'label': label,
                                        'description': description, 'snapshotIdentityPreserved': True})
                    require(not list(user.glob('cn_stellae.userdb*')) and
                            not list(user.glob('en_intelligence.userdb*')) and
                            not list(user.glob('jp_kanji.userdb*')),
                            'Display aliases created replacement learning databases')
                    dialog.send(dialog.window, WM_CLOSE)
                    require(process.wait(timeout=15) == 0, 'The dictionary manager failed to close')
                finally:
                    if process.poll() is None:
                        process.kill()
            report = Path(args.report)
            report.parent.mkdir(parents=True, exist_ok=True)
            report.write_text(json.dumps({'passed': True, 'syntheticFixtureOnly': True,
                                          'dictionaries': results}, indent=2) + '\n', encoding='utf-8')
        finally:
            for name, value in original.items():
                if value is None:
                    try:
                        winreg.DeleteValue(key, name)
                    except FileNotFoundError:
                        pass
                else:
                    winreg.SetValueEx(key, name, 0, value[1], value[0])


if __name__ == '__main__':
    main()
