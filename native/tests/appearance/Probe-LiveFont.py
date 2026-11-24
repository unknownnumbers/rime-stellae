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


ECHO, START, END, KEY = range(0x8001, 0x8005)
FOCUS_IN, MOVE_CARET = 0x8006, 0x8008
FRAME_BYTES = 64 * 1024  # PipeChannel default, including the native header.
SCHEMA_LIST, THEME_LIST, FONT_COMBO, PREVIEW = 1000, 1004, 1005, 1006
LB_GETCURSEL, LB_GETTEXT, LB_GETTEXTLEN = 0x0188, 0x0189, 0x018A
LB_GETCOUNT, LB_SETCURSEL = 0x018B, 0x0186
STM_GETIMAGE, IMAGE_BITMAP = 0x0173, 0
WM_COMMAND, IDOK = 0x0111, 1
WM_CLOSE = 0x0010
WM_KEYDOWN, WM_KEYUP, WM_NEXTDLGCTL = 0x0100, 0x0101, 0x0028
VK_HOME, VK_DOWN = 0x24, 0x28
DEFAULT_LABELS = {'Default', '默认', '預設'}
CB_GETCOUNT, CB_GETCURSEL, CB_GETLBTEXT, CB_GETLBTEXTLEN = (
    0x0146, 0x0147, 0x0148, 0x0149,
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
        self.is_enabled = api('IsWindowEnabled', w.BOOL, w.HWND)
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

    def cancel(self, window):
        if not self.post_message(window, WM_CLOSE, 0, 0):
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

    def select_font_by_keyboard(self, appearance, combo, index):
        require(self.is_visible(combo), 'The native candidate font control is hidden')
        require(self.is_enabled(combo), 'The native candidate font control is disabled')
        # Let the dialog set its own keyboard focus, then exercise the standard
        # combo-box key handler. CB_SETCURSEL bypasses disabled UI controls.
        self.send(appearance, WM_NEXTDLGCTL, combo, 1)
        for key in [VK_HOME] + [VK_DOWN] * index:
            self.send(combo, WM_KEYDOWN, key)
            self.send(combo, WM_KEYUP, key)
        require(self.send(combo, CB_GETCURSEL) == index,
                'Keyboard input did not select the replacement candidate font')

    def verify_theme_preview(self, appearance, report):
        themes = self.get_child(appearance, THEME_LIST)
        selected = self.send(themes, LB_GETCURSEL)
        require(selected >= 0, 'The native appearance settings have no current theme')
        length = self.send(themes, LB_GETTEXTLEN, selected)
        require(0 < length <= 512, 'Unexpected native theme name length')
        text = c.create_unicode_buffer(length + 1)
        require(self.send(themes, LB_GETTEXT, selected, c.addressof(text)) == length,
                'Could not read the current native theme name')
        require(text.value == '墨芯 / Rime Stellae',
                'The current native theme did not use the expected project name')
        preview = self.get_child(appearance, PREVIEW)
        require(preview and self.is_visible(preview) and
                self.send(preview, STM_GETIMAGE, IMAGE_BITMAP) != 0,
                'The current native theme did not load a preview bitmap')
        report['nativeSettingsThemeName'] = text.value
        report['nativeSettingsPreviewBitmapPresent'] = True

    def preview_bitmap(self, appearance):
        preview = self.get_child(appearance, PREVIEW)
        handle = self.send(preview, STM_GETIMAGE, IMAGE_BITMAP)
        require(handle, 'The selected font has no native preview bitmap')
        return handle


def font_item(items, family):
    if family == 'Microsoft YaHei':
        matches = [index for index, label in enumerate(items) if label in DEFAULT_LABELS]
        require(len(matches) == 1, 'The native font choices have no unique localized Default')
        return matches[0]
    return items.index(family)


def configuration_snapshot(profile):
    paths = list(profile.glob('*.yaml')) + [profile / 'build/weasel.yaml']
    return {str(path.relative_to(profile)): (digest(path), path.stat().st_mtime_ns)
            for path in paths if path.is_file()}


def preview_asset(installation, profile, family):
    suffix = {'Microsoft YaHei': '_default', 'Noto Sans CJK SC': '_sc',
              'Noto Sans CJK TC': '_tc', 'Noto Sans CJK HK': '_hk'}[family]
    for directory in [profile / 'preview', installation / 'data/preview']:
        for name in ['color_scheme_reference_gray' + suffix + '.png',
                     'color_scheme_reference_gray.png']:
            asset = directory / name
            if asset.is_file():
                return asset
    raise AssertionError('The selected font has no fixture preview asset')


def preview_and_cancel(installation, profile, initial_font, report):
    before = configuration_snapshot(profile)
    deployer = installation / 'StellaeDeployer.exe'
    with subprocess.Popen([str(deployer)], cwd=installation, stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL) as process:
        try:
            settings = SettingsDialog(process)
            switcher, _ = settings.wait_for(SCHEMA_LIST)
            settings.accept(switcher)
            appearance, combo = settings.wait_for(FONT_COMBO)
            settings.verify_theme_preview(appearance, report)
            items = settings.combo_items(combo)
            require(settings.send(combo, CB_GETCURSEL) == font_item(items, initial_font),
                    'Preview browsing started with the wrong candidate font')
            settings.preview_bitmap(appearance)
            asset_hashes = {}
            for family in ['Microsoft YaHei', 'Noto Sans CJK SC',
                           'Noto Sans CJK TC', 'Noto Sans CJK HK']:
                settings.select_font_by_keyboard(appearance, combo, font_item(items, family))
                settings.preview_bitmap(appearance)
                asset = preview_asset(installation, profile, family)
                asset_hashes[family] = digest(asset)
                content, stat = asset.read_bytes(), asset.stat()
                other = 'Noto Sans CJK SC' if family == 'Microsoft YaHei' else 'Microsoft YaHei'
                settings.select_font_by_keyboard(appearance, combo, font_item(items, other))
                try:
                    asset.write_bytes(b'not a PNG: synthetic family-resolution fixture')
                    settings.select_font_by_keyboard(appearance, combo, font_item(items, family))
                    preview = settings.get_child(appearance, PREVIEW)
                    require(settings.send(preview, STM_GETIMAGE, IMAGE_BITMAP) == 0,
                            'The font preview did not resolve its expected asset for ' + family)
                finally:
                    asset.write_bytes(content)
                    os.utime(asset, ns=(stat.st_atime_ns, stat.st_mtime_ns))
                settings.select_font_by_keyboard(appearance, combo, font_item(items, other))
                settings.select_font_by_keyboard(appearance, combo, font_item(items, family))
                settings.preview_bitmap(appearance)
                require(configuration_snapshot(profile) == before,
                        'Browsing font previews wrote or deployed the appearance configuration')
            require(len(set(asset_hashes.values())) == 4,
                    'The four font choices did not identify four distinct PNG assets')
            assets = [directory / name for directory in [profile / 'preview', installation / 'data/preview']
                      for name in ['color_scheme_reference_gray_sc.png', 'color_scheme_reference_gray.png']
                      if (directory / name).is_file()]
            require(assets, 'The fixture has no reference-theme preview files')
            saved = [(path, path.read_bytes(), path.stat()) for path in assets]
            try:
                assets[0].write_bytes(b'not a PNG: synthetic fixture')
                settings.select_font_by_keyboard(appearance, combo,
                                                 font_item(items, 'Noto Sans CJK SC'))
                preview = settings.get_child(appearance, PREVIEW)
                require(settings.send(preview, STM_GETIMAGE, IMAGE_BITMAP) == 0,
                        'A failed preview load retained the previous theme bitmap')
                for path in assets:
                    path.unlink()
                settings.select_font_by_keyboard(appearance, combo,
                                                 font_item(items, 'Noto Sans CJK HK'))
                settings.select_font_by_keyboard(appearance, combo,
                                                 font_item(items, 'Noto Sans CJK SC'))
                require(settings.send(preview, STM_GETIMAGE, IMAGE_BITMAP) == 0,
                        'A missing preview retained the previous theme bitmap')
            finally:
                for path, content, stat in saved:
                    path.write_bytes(content)
                    os.utime(path, ns=(stat.st_atime_ns, stat.st_mtime_ns))
            settings.select_font_by_keyboard(appearance, combo,
                                             font_item(items, 'Noto Sans CJK HK'))
            settings.preview_bitmap(appearance)
            report['failedAndMissingPreviewCleared'] = True
            settings.cancel(appearance)
            require(process.wait(timeout=30) == 0, 'Native preview settings did not cancel cleanly')
            require(configuration_snapshot(profile) == before,
                    'Cancelling the font preview changed configuration files')
            report['previewAssetSha256'] = asset_hashes
            report['previewAssetResolutionVerified'] = True
            report['previewCancelPreservedConfiguration'] = True
        finally:
            if process.poll() is None:
                process.kill()


def apply_through_settings(installation, initial_font, replacement_font, report):
    deployer = installation / 'StellaeDeployer.exe'
    with subprocess.Popen([str(deployer)], cwd=installation, stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL) as process:
        try:
            settings = SettingsDialog(process)
            switcher, _ = settings.wait_for(SCHEMA_LIST)
            settings.accept(switcher)
            appearance, combo = settings.wait_for(FONT_COMBO)
            settings.verify_theme_preview(appearance, report)
            require(settings.is_visible(combo) and settings.is_enabled(combo),
                    'The native candidate font control is not visible and enabled')
            report['nativeSettingsFontControlVisible'] = True
            report['nativeSettingsFontControlEnabled'] = True
            items = settings.combo_items(combo)
            require(all(f'Noto Sans CJK {style}' in items for style in ('SC', 'TC', 'HK')),
                    'The native appearance settings did not offer all three installed families')
            current = settings.send(combo, CB_GETCURSEL)
            require(0 <= current < len(items) and current == font_item(items, initial_font),
                    'The native appearance settings did not display the current candidate font')
            report['nativeSettingsInitialFont'] = items[current]
            replacement = font_item(items, replacement_font)
            settings.select_font_by_keyboard(appearance, combo, replacement)
            report['nativeSettingsSelectionMethod'] = 'keyboard-home-down'
            start = time.monotonic()
            settings.accept(appearance)
            require(process.wait(timeout=90) == 0, 'Native settings did not apply the replacement font')
            report['applyMilliseconds'] = round((time.monotonic() - start) * 1000)
            report['nativeSettingsReplacementFont'] = replacement_font
        finally:
            if process.poll() is None:
                process.kill()


def verify_custom_font_defaults(installation, profile, report):
    """Use fixed CI-only custom values, then restore the fixture configuration."""
    import yaml

    custom = profile / 'weasel.custom.yaml'
    original = custom.read_bytes()
    custom_stack = 'Microsoft YaHei, Noto Sans CJK TC'
    deployer = installation / 'StellaeDeployer.exe'

    def compile_appearance():
        subprocess.run([str(deployer), '/deploy-appearance'], cwd=installation,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                       check=True, timeout=90)

    def style():
        return yaml.safe_load((profile / 'build/weasel.yaml').read_text(encoding='utf-8-sig'))['style']

    def configure(default):
        with subprocess.Popen([str(deployer)], cwd=installation, stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL) as process:
            try:
                settings = SettingsDialog(process)
                switcher, _ = settings.wait_for(SCHEMA_LIST)
                settings.accept(switcher)
                appearance, combo = settings.wait_for(FONT_COMBO)
                items = settings.combo_items(combo)
                require(settings.send(combo, CB_GETCURSEL) == items.index(custom_stack),
                        'An explicit custom fallback stack was mislabeled as Default')
                if default:
                    settings.select_font_by_keyboard(appearance, combo,
                                                     font_item(items, 'Microsoft YaHei'))
                else:
                    themes = settings.get_child(appearance, THEME_LIST)
                    count = settings.send(themes, LB_GETCOUNT)
                    require(count > 1, 'The fixture needs an unrelated theme choice')
                    current = settings.send(themes, LB_GETCURSEL)
                    selected = 0 if current != 0 else 1
                    settings.send(themes, LB_SETCURSEL, selected)
                    settings.send(appearance, WM_COMMAND, THEME_LIST | (1 << 16), themes)
                settings.accept(appearance)
                require(process.wait(timeout=90) == 0, 'The custom-font settings did not apply')
            finally:
                if process.poll() is None:
                    process.kill()

    try:
        data = yaml.safe_load(original)
        patch = data.setdefault('patch', {})
        patch['style/font_face'] = custom_stack
        patch['style/label_font_face'] = custom_stack
        patch['style/comment_font_face'] = 'Consolas'
        custom.write_text(yaml.safe_dump(data, allow_unicode=True, sort_keys=False), encoding='utf-8')
        compile_appearance()
        require(style()['font_face'] == custom_stack, 'The synthetic fallback fixture did not load')
        configure(False)
        unchanged = style()
        require(unchanged['font_face'] == custom_stack and
                unchanged['label_font_face'] == custom_stack and
                unchanged['comment_font_face'] == 'Consolas',
                'Saving an unrelated theme rewrote a custom font stack')
        configure(True)
        default = style()
        require(default['font_face'] == 'Microsoft YaHei' and
                default['label_font_face'] == 'Microsoft YaHei' and
                default['comment_font_face'] == 'Consolas',
                'Default did not reset inherited fonts while preserving a distinct custom font')
        report['customStackPreservedByUnrelatedTheme'] = True
        report['defaultClearedInheritedStackOnly'] = True
        distinct_label = 'Microsoft YaHei, Segoe UI'
        patch['style/label_font_face'] = distinct_label
        custom.write_text(yaml.safe_dump(data, allow_unicode=True, sort_keys=False), encoding='utf-8')
        compile_appearance()
        configure(True)
        distinct = style()
        require(distinct['font_face'] == 'Microsoft YaHei' and
                distinct['label_font_face'] == distinct_label and
                distinct['comment_font_face'] == 'Consolas',
                'Default removed a distinct fallback stack sharing the same primary font')
        report['defaultPreservedDistinctSamePrimaryFallback'] = True
    finally:
        custom.write_bytes(original)
        compile_appearance()


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
        report['phase'] = 'preview without applying, then cancel'
        preview_and_cancel(installation, profile, initial_font, report)
        unchanged = read_frames(trace)[-1]
        require((unchanged.window, unchanged.composition, unchanged.selected,
                 unchanged.count, unchanged.family) ==
                (before.window, before.composition, before.selected, before.count, initial_font),
                'Browsing or cancelling the preview changed the live font or draft')
        report['previewCancelPreservedDraft'] = True

        report['phase'] = 'apply Default through native settings'
        default_report = {}
        apply_through_settings(installation, initial_font, 'Microsoft YaHei', default_report)
        default_frame, offset = wait_for_frame(trace, args.server_pid, offset, 'Microsoft YaHei')
        require((before.window, before.composition, before.selected, before.count) ==
                (default_frame.window, default_frame.composition,
                 default_frame.selected, default_frame.count),
                'Applying Default changed the live candidate window or draft')
        report['defaultApply'] = default_report
        report['defaultFrame'] = asdict(default_frame)
        report['phase'] = 'native appearance-only apply'
        apply_through_settings(installation, 'Microsoft YaHei', replacement_font, report)

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
    report['phase'] = 'custom fallback and Default configuration'
    verify_custom_font_defaults(installation, profile, report)


def main():
    require(os.name == 'nt' and os.environ.get('GITHUB_ACTIONS') == 'true' and
            os.environ.get('RUNNER_ENVIRONMENT') == 'github-hosted',
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
