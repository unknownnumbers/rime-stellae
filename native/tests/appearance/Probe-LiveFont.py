"""Verify a live candidate frame in an exclusively disposable CI installation."""

# SPDX-License-Identifier: GPL-3.0-only
import argparse
import ctypes as c
from ctypes import wintypes as w
from dataclasses import asdict, dataclass
from hashlib import file_digest
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import time


REPO = 'unknownnumbers/rime-stellae'
ECHO, START, END, KEY = range(0x8001, 0x8005)
FOCUS_IN, MOVE_CARET = 0x8006, 0x8008
FRAME_BYTES = 64 * 1024  # PipeChannel default, including the native header.
SCHEMA_LIST, FONT_COMBO = 1000, 1005
WM_COMMAND, IDOK = 0x0111, 1
CB_GETCOUNT, CB_GETCURSEL, CB_GETLBTEXT, CB_GETLBTEXTLEN, CB_SETCURSEL = (
    0x0146, 0x0147, 0x0148, 0x0149, 0x014E,
)


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def win_function(library, name, result, *arguments):
    function = getattr(library, name)
    function.restype = result
    function.argtypes = arguments
    return function


class ProbeClient:
    """Use the same message framing as ClientImpl, with fixture-only input."""

    def __init__(self, expected_pid):
        kernel = c.WinDLL('kernel32', use_last_error=True)
        api = lambda name, result, *arguments: win_function(kernel, name, result, *arguments)
        create = api('CreateFileW', w.HANDLE, w.LPCWSTR, w.DWORD, w.DWORD, c.c_void_p,
                     w.DWORD, w.DWORD, w.HANDLE)
        self.close_handle = api('CloseHandle', w.BOOL, w.HANDLE)
        self.read_file = api('ReadFile', w.BOOL, w.HANDLE, c.c_void_p, w.DWORD,
                             c.POINTER(w.DWORD), c.c_void_p)
        self.write_file = api('WriteFile', w.BOOL, w.HANDLE, c.c_void_p, w.DWORD,
                              c.POINTER(w.DWORD), c.c_void_p)
        pipe_name = fr'\\.\pipe\{os.environ["USERNAME"]}\RimeStellaeNamedPipe'
        invalid_handle = c.c_void_p(-1).value
        stop = time.monotonic() + 20
        while True:
            self.handle = create(pipe_name, 0xC0000000, 0, None, 3, 0, None)
            if self.handle not in {None, invalid_handle}:
                break
            error = c.get_last_error()
            if error not in {2, 231} or time.monotonic() >= stop:
                raise c.WinError(error)
            time.sleep(0.1)

        try:
            pipe_pid = w.DWORD()
            get_server_pid = api('GetNamedPipeServerProcessId', w.BOOL, w.HANDLE,
                                 c.POINTER(w.DWORD))
            require(get_server_pid(self.handle, c.byref(pipe_pid)) and
                    pipe_pid.value == expected_pid, 'Pipe server differs from the CI probe process')
            mode = w.DWORD(2)  # PIPE_READMODE_MESSAGE
            set_mode = api('SetNamedPipeHandleState', w.BOOL, w.HANDLE, c.POINTER(w.DWORD),
                           c.POINTER(w.DWORD), c.POINTER(w.DWORD))
            if not set_mode(self.handle, c.byref(mode), None, None):
                raise c.WinError(c.get_last_error())
        except Exception:
            self.close_handle(self.handle)
            raise

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close_handle(self.handle)

    def request(self, message, parameter=0, session=0, body=''):
        payload = struct.pack('<III', message, parameter, session)
        if body:
            payload = (payload + body.encode('utf-16-le')).ljust(FRAME_BYTES, b'\0')
        size = w.DWORD()
        if not self.write_file(self.handle, payload, len(payload), c.byref(size), None):
            raise c.WinError(c.get_last_error())
        require(size.value == len(payload), 'Incomplete fixture pipe request')

        buffer = c.create_string_buffer(FRAME_BYTES)
        if not self.read_file(self.handle, buffer, FRAME_BYTES, c.byref(size), None):
            raise c.WinError(c.get_last_error())
        require(size.value in {4, FRAME_BYTES}, 'Unexpected fixture response length')
        reply, = struct.unpack_from('<I', buffer)
        text = buffer.raw[4:size.value].decode('utf-16-le').split('\0', 1)[0]
        return reply, text


@dataclass(frozen=True)
class Frame:
    window: int
    composition: int
    selected: int
    count: int
    family: str


def read_frames(trace):
    if not trace.exists():
        return []
    frames = []
    for line in trace.read_text(encoding='utf-8').splitlines():
        fields = line.split('\t')
        if len(fields) == 5:
            frames.append(Frame(*(int(value) for value in fields[:4]), fields[4]))
    return frames


def wait_for_frame(trace, pid, offset=0, expected_family=None):
    user = c.WinDLL('user32', use_last_error=True)
    is_visible = win_function(user, 'IsWindowVisible', w.BOOL, w.HWND)
    get_pid = win_function(user, 'GetWindowThreadProcessId', w.DWORD, w.HWND,
                           c.POINTER(w.DWORD))
    stop = time.monotonic() + 8
    while time.monotonic() < stop:
        frames = read_frames(trace)
        for frame in reversed(frames[offset:]):
            if expected_family and frame.family != expected_family:
                continue
            owner = w.DWORD()
            if get_pid(frame.window, c.byref(owner)) and owner.value == pid and is_visible(frame.window):
                return frame, len(frames)
        time.sleep(0.05)
    raise AssertionError('No rendered, visible candidate window appeared')


class SettingsDialog:
    """Drive only the production settings process started by this fixture."""

    def __init__(self, process):
        self.process = process
        user = c.WinDLL('user32', use_last_error=True)
        api = lambda name, result, *arguments: win_function(user, name, result, *arguments)
        self.callback = c.WINFUNCTYPE(w.BOOL, w.HWND, w.LPARAM)
        self.enum_windows = api('EnumWindows', w.BOOL, self.callback, w.LPARAM)
        self.get_pid = api('GetWindowThreadProcessId', w.DWORD, w.HWND, c.POINTER(w.DWORD))
        self.is_visible = api('IsWindowVisible', w.BOOL, w.HWND)
        self.get_child = api('GetDlgItem', w.HWND, w.HWND, c.c_int)
        self.post_message = api('PostMessageW', w.BOOL, w.HWND, w.UINT, w.WPARAM, w.LPARAM)
        self.send_message = api('SendMessageTimeoutW', w.LPARAM, w.HWND, w.UINT,
                                w.WPARAM, w.LPARAM, w.UINT, w.UINT, c.POINTER(c.c_size_t))

    def wait_for(self, control):
        matches = []

        @self.callback
        def match(window, _):
            owner = w.DWORD()
            self.get_pid(window, c.byref(owner))
            if owner.value == self.process.pid and self.is_visible(window):
                child = self.get_child(window, control)
                if child:
                    matches.append((window, child))
            return True

        until = time.monotonic() + 30
        while time.monotonic() < until:
            require(self.process.poll() is None,
                    f'Native settings closed before displaying control {control}')
            if not self.enum_windows(match, 0):
                raise c.WinError(c.get_last_error())
            if matches:
                require(len(matches) == 1, f'Unexpected duplicate settings control {control}')
                return matches[0]
            time.sleep(0.05)
        raise AssertionError(f'Native settings did not display control {control}')

    def send(self, window, message, parameter=0, pointer=0):
        result = c.c_size_t()
        if not self.send_message(window, message, parameter, pointer, 2, 5000, c.byref(result)):
            raise c.WinError(c.get_last_error())
        return c.c_ssize_t(result.value).value

    def accept(self, window):
        if not self.post_message(window, WM_COMMAND, IDOK, 0):
            raise c.WinError(c.get_last_error())

    def combo_items(self, combo):
        count = self.send(combo, CB_GETCOUNT)
        require(3 <= count <= 10, 'Unexpected native font choice count')
        items = []
        for index in range(count):
            length = self.send(combo, CB_GETLBTEXTLEN, index)
            require(0 < length <= 512, 'Unexpected native font choice text length')
            text = c.create_unicode_buffer(length + 1)
            require(self.send(combo, CB_GETLBTEXT, index, c.addressof(text)) == length,
                    'Could not read the native font choice')
            items.append(text.value)
        return items


def apply_through_settings(installation, initial_font, replacement_font, report):
    deployer = installation / 'StellaeDeployer.exe'
    with subprocess.Popen([str(deployer)], cwd=installation, stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL) as process:
        try:
            settings = SettingsDialog(process)
            switcher, _ = settings.wait_for(SCHEMA_LIST)
            settings.accept(switcher)
            appearance, combo = settings.wait_for(FONT_COMBO)
            items = settings.combo_items(combo)
            require(all(f'Noto Sans CJK {style}' in items for style in ('SC', 'TC', 'HK')),
                    'The native appearance settings did not offer all three installed families')
            current = settings.send(combo, CB_GETCURSEL)
            require(0 <= current < len(items) and items[current] == initial_font,
                    'The native appearance settings did not display the current candidate font')
            report['nativeSettingsInitialFont'] = items[current]
            replacement = items.index(replacement_font)
            require(settings.send(combo, CB_SETCURSEL, replacement) == replacement,
                    'Could not select the replacement font in native settings')
            start = time.monotonic()
            settings.accept(appearance)
            require(process.wait(timeout=90) == 0, 'Native settings did not apply the replacement font')
            report['applyMilliseconds'] = round((time.monotonic() - start) * 1000)
            report['nativeSettingsReplacementFont'] = replacement_font
        finally:
            if process.poll() is None:
                process.kill()


def digest(path):
    with path.open('rb') as stream:
        return file_digest(stream, 'sha256').hexdigest()


def scheme_snapshot(installation, profile):
    entries = {}
    folders = {'compiled': profile / 'build', 'shared': installation / 'data'}
    for category, folder in folders.items():
        for path in folder.rglob('*'):
            if path.is_file() and path.name != 'weasel.yaml':
                relative = path.relative_to(folder).as_posix()
                stat = path.stat()
                entries[f'{category}/{relative}'] = (digest(path), stat.st_size, stat.st_mtime_ns)
    loaded = {name for name in entries if name.startswith('compiled/')}
    for suffix in ('.schema.yaml', '.table.bin', '.prism.bin', '.reverse.bin'):
        require(any(name.endswith(suffix) for name in loaded),
                f'Test installation has no compiled {suffix} files')
    return entries


def selected_fingerprint(text):
    hash_value = 14695981039346656037
    for (unit,) in struct.iter_unpack('<H', text.encode('utf-16-le')):
        hash_value = ((hash_value ^ unit) * 1099511628211) & ((1 << 64) - 1)
    return hash_value


def validate(args, report):
    profile = Path(args.profile)
    installation = Path(args.installation)
    trace = Path(args.trace)
    initial_font = f'Noto Sans CJK {args.default_font}'
    replacement_font = 'Noto Sans CJK HK'
    report['phase'] = 'compose'
    with ProbeClient(args.server_pid) as client:
        session, _ = client.request(
            START, body='action=session\nsession.client_app=appearance-ci.exe\n'
                        'session.client_type=ime\n.\n')
        require(session, 'The server did not start an isolated input session')
        client.request(FOCUS_IN, session=session)
        client.request(MOVE_CARET, (20 << 24) | (120 << 12) | 120, session)
        for key in 'ni':
            handled, response = client.request(KEY, ord(key), session)
            require(handled == 1, 'Synthetic composition key was rejected')
        require('ctx.cand=' in response and 'ctx.preedit=' in response,
                'The actual server did not return a composition and candidates')
        before, _ = wait_for_frame(trace, args.server_pid)
        report['before'] = asdict(before)
        require(before.family == initial_font,
                'Initial candidate glyphs did not use the selected installer default font')

        # Leave a deterministic reason for a *full* deploy to recompile, even
        # if the GitHub VM copied every dictionary with the same timestamp.
        default = installation / 'data/default.yaml'
        default_stat = default.stat()
        os.utime(default, ns=(default_stat.st_atime_ns, default_stat.st_mtime_ns + 10_000_000_000))
        files_before = scheme_snapshot(installation, profile)
        appearance_before = digest(profile / 'build/weasel.yaml')
        offset = len(read_frames(trace))
        report['phase'] = 'native appearance-only apply'
        apply_through_settings(installation, initial_font, replacement_font, report)

        # Observe the real repaint before sending any further IPC request.
        report['phase'] = 'repaint and compare'
        after, _ = wait_for_frame(trace, args.server_pid, offset, replacement_font)
        report['after'] = asdict(after)
        require((before.window, before.composition, before.selected, before.count) ==
                (after.window, after.composition, after.selected, after.count),
                'The pre-existing candidate window or its draft changed during appearance reload')
        files_after = scheme_snapshot(installation, profile)
        changed = sorted(name for name in set(files_before) | set(files_after)
                         if files_before.get(name) != files_after.get(name))
        report['schemeFilesChecked'] = len(files_before)
        report['changedSchemeFiles'] = changed
        require(not changed, 'Appearance changed scheme or dictionary artifacts')
        require(digest(profile / 'build/weasel.yaml') != appearance_before,
                'Appearance compilation did not update its own output')

        report['phase'] = 'commit retained draft'
        reply, _ = client.request(ECHO, session=session)
        require(reply == session, 'The same Rime input session no longer exists')
        handled, response = client.request(KEY, ord(' '), session)
        commit = re.search(r'(?m)^commit=(.+)$', response)
        require(handled == 1 and commit is not None and
                selected_fingerprint(commit.group(1)) == before.selected,
                'The candidate selected before the font switch did not commit from the retained draft')
        require('status.composing=0' in response, 'Commit did not finish the retained composition')
        client.request(END, session=session)
        report['sameSessionCommitted'] = True


def main():
    require(os.name == 'nt' and os.environ.get('GITHUB_ACTIONS') == 'true' and
            os.environ.get('RUNNER_ENVIRONMENT') == 'github-hosted' and
            os.environ.get('GITHUB_REPOSITORY') == REPO,
            'Run only on the disposable GitHub-hosted Windows CI runner')
    parser = argparse.ArgumentParser()
    for option in ('installation', 'profile', 'trace', 'report'):
        parser.add_argument(f'--{option}', required=True)
    parser.add_argument('--default-font', choices=('SC', 'TC'), required=True)
    parser.add_argument('--server-pid', type=int, required=True)
    args = parser.parse_args()
    report = {'passed': False, 'phase': 'initialize'}
    try:
        validate(args, report)
        report['passed'] = True
        report['phase'] = 'passed'
    except Exception as error:
        report['failure'] = str(error)
        raise
    finally:
        Path(args.report).write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')


if __name__ == '__main__':
    main()
