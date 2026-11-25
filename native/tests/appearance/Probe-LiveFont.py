"""Verify a live candidate frame in an exclusively disposable CI installation."""

# SPDX-License-Identifier: GPL-3.0-only
import argparse
import ctypes as c
from ctypes import wintypes as w
from contextlib import contextmanager
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
SCHEMA_LIST, THEME_LIST, FONT_COMBO, PREVIEW, FONT_PREVIEW = 1000, 1004, 1005, 1006, 1013
LB_GETCURSEL, LB_GETTEXT, LB_GETTEXTLEN = 0x0188, 0x0189, 0x018A
LB_GETCOUNT, LB_SETCURSEL = 0x018B, 0x0186
STM_GETIMAGE, IMAGE_BITMAP = 0x0173, 0
WM_COMMAND, IDOK = 0x0111, 1
WM_CLOSE = 0x0010
WM_KEYDOWN, WM_KEYUP, WM_NEXTDLGCTL = 0x0100, 0x0101, 0x0028
VK_HOME, VK_DOWN = 0x24, 0x28
DEFAULT_LABELS = {'Default (Microsoft YaHei)'}
BUILTIN_THEMES = ('reference_gray', 'stellae_sakura', 'stellae_lavender',
                  'stellae_night', 'stellae_crimson', 'stellae_mono')
CUSTOM_THEME = 'ci_custom_theme'
STYLE_COLORS = ('back_color', 'candidate_text_color',
                'hilited_candidate_back_color', 'hilited_candidate_text_color')
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
    back_color: int
    candidate_text_color: int
    hilited_candidate_back_color: int
    hilited_candidate_text_color: int


def read_frames(trace):
    if not trace.exists():
        return []
    frames = []
    for line in trace.read_text(encoding='utf-8').splitlines():
        fields = line.split('\t')
        if len(fields) == 9:
            frames.append(Frame(*(int(value) for value in fields[:4]), fields[4],
                                *(int(value) for value in fields[5:])))
    return frames


def wait_for_frame(trace, pid, offset=0, expected_family=None, expected_colors=None):
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
            if expected_colors and any(getattr(frame, key) != value
                                       for key, value in expected_colors.items()):
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
        self.get_window_rect = api('GetWindowRect', w.BOOL, w.HWND, c.POINTER(w.RECT))
        self.get_client_rect = api('GetClientRect', w.BOOL, w.HWND, c.POINTER(w.RECT))
        self.client_to_screen = api('ClientToScreen', w.BOOL, w.HWND, c.POINTER(w.POINT))
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
        require(self.preview_bitmap(appearance, FONT_PREVIEW),
                'The native settings did not load its independent font preview')
        report['nativeSettingsFontPreviewBitmapPresent'] = True
        self.verify_preview_layout(appearance, report)

    def verify_preview_layout(self, appearance, report):
        client, origin = w.RECT(), w.POINT()
        require(self.get_client_rect(appearance, c.byref(client)) and
                self.client_to_screen(appearance, c.byref(origin)),
                'Could not inspect the dialog client area')
        bounds = {}
        for control in (PREVIEW, FONT_PREVIEW, FONT_COMBO):
            rectangle = w.RECT()
            require(self.get_window_rect(self.get_child(appearance, control), c.byref(rectangle)),
                    'Could not inspect a preview control rectangle')
            values = (rectangle.left - origin.x, rectangle.top - origin.y,
                      rectangle.right - origin.x, rectangle.bottom - origin.y)
            require(0 <= values[0] < values[2] <= client.right and
                    0 <= values[1] < values[3] <= client.bottom,
                    'A preview or font selector is clipped outside the dialog')
            bounds[control] = values
        skin, font, combo = (bounds[k] for k in (PREVIEW, FONT_PREVIEW, FONT_COMBO))
        require(skin[2] - skin[0] >= 348 and skin[3] - skin[1] >= 190,
                'The theme preview control is smaller than its image')
        require(font[2] - font[0] >= 348 and font[3] - font[1] >= 150,
                'The font preview control is smaller than its image')
        disjoint = (skin[2] <= font[0] or font[2] <= skin[0] or
                    skin[3] <= font[1] or font[3] <= skin[1])
        require(disjoint and max(skin[3], font[3]) <= combo[1],
                'The theme preview, font preview and selector overlap')
        report['independentPreviewBounds'] = {str(k): list(v) for k, v in bounds.items()}

    def preview_bitmap(self, appearance, control=PREVIEW, required=True):
        preview = self.get_child(appearance, control)
        require(preview and self.is_visible(preview), 'A native preview control is missing or hidden')
        handle = self.send(preview, STM_GETIMAGE, IMAGE_BITMAP)
        if required:
            require(handle, 'The selected item has no native preview bitmap')
        return handle

    def theme_items(self, appearance):
        themes = self.get_child(appearance, THEME_LIST)
        count = self.send(themes, LB_GETCOUNT)
        require(len(BUILTIN_THEMES) <= count <= len(BUILTIN_THEMES) + 1,
                'Unexpected builtin or custom theme count')
        items = []
        for index in range(count):
            length = self.send(themes, LB_GETTEXTLEN, index)
            require(0 < length <= 512, 'Unexpected theme name length')
            text = c.create_unicode_buffer(length + 1)
            require(self.send(themes, LB_GETTEXT, index, c.addressof(text)) == length,
                    'Could not read a native theme name')
            items.append(text.value)
        return themes, items

    def select_theme(self, appearance, themes, index):
        require(self.send(themes, LB_SETCURSEL, index) >= 0, 'Could not select the native theme')
        self.send(appearance, WM_COMMAND, THEME_LIST | (1 << 16), themes)


def font_item(items, family):
    if family == 'Microsoft YaHei':
        matches = [index for index, label in enumerate(items) if label in DEFAULT_LABELS]
        require(len(matches) == 1,
                'The native font choices have no unique Default label naming Microsoft YaHei')
        return matches[0]
    return items.index(family)


def configuration_snapshot(profile):
    paths = list(profile.glob('*.yaml')) + [profile / 'build/stellae.yaml']
    return {str(path.relative_to(profile)): (digest(path), path.stat().st_mtime_ns)
            for path in paths if path.is_file()}


def next_configuration_second(profile, report, operation):
    # Pinned librime's ConfigNeedsUpdate compares whole-second source mtimes.
    # Keep this rapid synthetic sequence distinct under that upstream contract.
    custom = profile / 'stellae.custom.yaml'
    previous = custom.stat().st_mtime_ns // 1_000_000_000
    delay = previous + 1.05 - time.time()
    require(delay < 5, 'The fixture configuration timestamp is ahead of the runner clock')
    if delay > 0:
        time.sleep(delay)
    ready = time.time_ns() // 1_000_000_000
    require(ready > previous, 'The fixture did not cross the upstream timestamp boundary')
    event = {'operation': operation, 'previousSourceSecond': previous, 'readySecond': ready}
    report.setdefault('configurationClock', []).append(event)
    return event


def record_configuration_write(profile, event):
    actual = (profile / 'stellae.custom.yaml').stat().st_mtime_ns // 1_000_000_000
    event['writtenSourceSecond'] = actual
    require(actual >= event['readySecond'] and actual > event['previousSourceSecond'],
            'The fixture configuration write reused its previous cached timestamp')


def preview_asset(installation, profile, family):
    suffix = {'Microsoft YaHei': '_default', 'Noto Sans CJK SC': '_sc',
              'Noto Sans CJK TC': '_tc', 'Noto Sans CJK HK': '_hk'}[family]
    for directory in [profile / 'preview', installation / 'data/preview']:
        for name in ['candidate_font' + suffix + '.png', 'candidate_font.png']:
            asset = directory / name
            if asset.is_file():
                return asset
    raise AssertionError('The selected font has no fixture preview asset')


def theme_asset(installation, profile, theme):
    for directory in [profile / 'preview', installation / 'data/preview']:
        asset = directory / ('color_scheme_' + theme + '.png')
        if asset.is_file():
            return asset
    raise AssertionError('The builtin theme has no fixture preview asset')


def compiled_themes(profile):
    import yaml
    config = yaml.safe_load((profile / 'build/stellae.yaml').read_text(encoding='utf-8-sig'))
    themes = config['preset_color_schemes']
    require(set(themes) == {*BUILTIN_THEMES, CUSTOM_THEME},
            'The installed themes differ from the six builtins and retained custom fixture')
    return themes


@contextmanager
def effective_dark_reader(engine, shared, profile, logs):
    """Read the same compiled CustomSettings value used by the native dialog."""
    class Traits(c.Structure):
        _fields_ = [('data_size', c.c_int)] + [(name, c.c_char_p) for name in (
            'shared_data_dir', 'user_data_dir', 'distribution_name', 'distribution_code_name',
            'distribution_version', 'app_name')] + [('modules', c.c_void_p),
            ('min_log_level', c.c_int), ('log_dir', c.c_char_p),
            ('prebuilt_data_dir', c.c_char_p), ('staging_dir', c.c_char_p)]
    class Module(c.Structure):
        _fields_ = [('data_size', c.c_int), ('module_name', c.c_char_p),
                    ('initialize', c.c_void_p), ('finalize', c.c_void_p), ('get_api', c.c_void_p)]
    class Levers(c.Structure):
        _fields_ = [('data_size', c.c_int)] + [(name, c.c_void_p) for name in (
            'custom_settings_init', 'custom_settings_destroy', 'load_settings', 'save_settings',
            'customize_bool', 'customize_int', 'customize_double', 'customize_string',
            'is_first_run', 'settings_is_modified', 'settings_get_config')]
    class Config(c.Structure):
        _fields_ = [('ptr', c.c_void_p)]
    logs.mkdir(parents=True, exist_ok=True)
    with os.add_dll_directory(str(engine.parent)):
        library = c.CDLL(str(engine))
        traits = Traits()
        traits.data_size = c.sizeof(traits) - c.sizeof(c.c_int)
        traits.shared_data_dir, traits.user_data_dir = str(shared).encode(), str(profile).encode()
        traits.prebuilt_data_dir, traits.staging_dir = str(shared).encode(), str(profile / 'build').encode()
        traits.log_dir, traits.min_log_level = str(logs).encode(), 2
        traits.app_name = b'rime.appearance_custom_settings_fixture'
        win_function(library, 'RimeSetup', None, c.POINTER(Traits))(c.byref(traits))
        win_function(library, 'RimeDeployerInitialize', None, c.c_void_p)(None)
        try:
            module = win_function(library, 'RimeFindModule', c.POINTER(Module), c.c_char_p)(b'levers')
            require(module, 'The fixture could not find the native levers module')
            api = c.CFUNCTYPE(c.POINTER(Levers))(module.contents.get_api)().contents
            def lever(name, result, parameters):
                return c.CFUNCTYPE(result, *parameters)(getattr(api, name))
            def read():
                settings = lever('custom_settings_init', c.c_void_p, (c.c_char_p, c.c_char_p))(
                    b'stellae', b'appearance-fixture')
                require(settings, 'The fixture could not create native CustomSettings')
                try:
                    require(lever('load_settings', c.c_int, (c.c_void_p,))(settings),
                            'The fixture could not load native CustomSettings')
                    config = Config()
                    require(lever('settings_get_config', c.c_int,
                                  (c.c_void_p, c.POINTER(Config)))(settings, c.byref(config)),
                            'The fixture could not inspect the native settings configuration')
                    value = win_function(library, 'RimeConfigGetCString', c.c_char_p,
                                         c.POINTER(Config), c.c_char_p)(
                                             c.byref(config), b'style/color_scheme_dark')
                    return None if value is None else value.decode('utf-8')
                finally:
                    lever('custom_settings_destroy', None, (c.c_void_p,))(settings)
            yield read
        finally:
            win_function(library, 'RimeFinalize', None)()


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
            skin_bitmap = settings.preview_bitmap(appearance)
            settings.preview_bitmap(appearance, FONT_PREVIEW)
            asset_hashes = {}
            for family in ['Microsoft YaHei', 'Noto Sans CJK SC',
                           'Noto Sans CJK TC', 'Noto Sans CJK HK']:
                settings.select_font_by_keyboard(appearance, combo, font_item(items, family))
                settings.preview_bitmap(appearance, FONT_PREVIEW)
                require(settings.preview_bitmap(appearance) == skin_bitmap,
                        'Selecting a font replaced the independent skin preview')
                asset = preview_asset(installation, profile, family)
                asset_hashes[family] = digest(asset)
                content, stat = asset.read_bytes(), asset.stat()
                other = 'Noto Sans CJK SC' if family == 'Microsoft YaHei' else 'Microsoft YaHei'
                settings.select_font_by_keyboard(appearance, combo, font_item(items, other))
                try:
                    asset.write_bytes(b'not a PNG: synthetic family-resolution fixture')
                    settings.select_font_by_keyboard(appearance, combo, font_item(items, family))
                    preview = settings.get_child(appearance, FONT_PREVIEW)
                    require(settings.send(preview, STM_GETIMAGE, IMAGE_BITMAP) == 0,
                            'The font preview did not resolve its expected asset for ' + family)
                    require(settings.preview_bitmap(appearance) == skin_bitmap,
                            'A corrupt font preview cleared the independent skin preview')
                finally:
                    asset.write_bytes(content)
                    os.utime(asset, ns=(stat.st_atime_ns, stat.st_mtime_ns))
                settings.select_font_by_keyboard(appearance, combo, font_item(items, other))
                settings.select_font_by_keyboard(appearance, combo, font_item(items, family))
                settings.preview_bitmap(appearance, FONT_PREVIEW)
                require(configuration_snapshot(profile) == before,
                        'Browsing font previews wrote or deployed the appearance configuration')
            require(len(set(asset_hashes.values())) == 4,
                    'The four font choices did not identify four distinct PNG assets')
            assets = [directory / name for directory in [profile / 'preview', installation / 'data/preview']
                      for name in ['candidate_font_sc.png', 'candidate_font.png']
                      if (directory / name).is_file()]
            require(assets, 'The fixture has no font-comparison preview files')
            saved = [(path, path.read_bytes(), path.stat()) for path in assets]
            try:
                assets[0].write_bytes(b'not a PNG: synthetic fixture')
                settings.select_font_by_keyboard(appearance, combo,
                                                 font_item(items, 'Noto Sans CJK SC'))
                preview = settings.get_child(appearance, FONT_PREVIEW)
                require(settings.send(preview, STM_GETIMAGE, IMAGE_BITMAP) == 0,
                        'A failed font preview load retained its previous bitmap')
                for path in assets:
                    path.unlink()
                settings.select_font_by_keyboard(appearance, combo,
                                                 font_item(items, 'Noto Sans CJK HK'))
                settings.select_font_by_keyboard(appearance, combo,
                                                 font_item(items, 'Noto Sans CJK SC'))
                require(settings.send(preview, STM_GETIMAGE, IMAGE_BITMAP) == 0,
                        'A missing font preview retained its previous bitmap')
                require(settings.preview_bitmap(appearance) == skin_bitmap,
                        'A missing font preview cleared the independent skin preview')
            finally:
                for path, content, stat in saved:
                    path.write_bytes(content)
                    os.utime(path, ns=(stat.st_atime_ns, stat.st_mtime_ns))
            settings.select_font_by_keyboard(appearance, combo,
                                             font_item(items, 'Noto Sans CJK HK'))
            font_bitmap = settings.preview_bitmap(appearance, FONT_PREVIEW)
            report['failedAndMissingFontPreviewClearedOnlyItself'] = True
            themes, theme_labels = settings.theme_items(appearance)
            palettes = compiled_themes(profile)
            require(set(theme_labels) == {value['name'] for value in palettes.values()},
                    'The native theme list lost a custom theme or retained an old builtin')
            skin_hashes = {}
            for theme in BUILTIN_THEMES:
                target = theme_labels.index(palettes[theme]['name'])
                other_theme = 'stellae_sakura' if theme == 'reference_gray' else 'reference_gray'
                other = theme_labels.index(palettes[other_theme]['name'])
                settings.select_theme(appearance, themes, target)
                settings.preview_bitmap(appearance)
                require(settings.preview_bitmap(appearance, FONT_PREVIEW) == font_bitmap,
                        'Selecting a theme replaced the independent font preview')
                asset = theme_asset(installation, profile, theme)
                skin_hashes[theme] = digest(asset)
                content, stat = asset.read_bytes(), asset.stat()
                settings.select_theme(appearance, themes, other)
                try:
                    asset.write_bytes(b'not a PNG: synthetic theme-resolution fixture')
                    settings.select_theme(appearance, themes, target)
                    require(settings.preview_bitmap(appearance, required=False) == 0,
                            'A theme preview did not resolve its expected PNG')
                    require(settings.preview_bitmap(appearance, FONT_PREVIEW) == font_bitmap,
                            'A corrupt skin preview cleared the independent font preview')
                finally:
                    asset.write_bytes(content)
                    os.utime(asset, ns=(stat.st_atime_ns, stat.st_mtime_ns))
                settings.select_theme(appearance, themes, other)
                settings.select_theme(appearance, themes, target)
                settings.preview_bitmap(appearance)
            require(len(set(skin_hashes.values())) == len(BUILTIN_THEMES),
                    'The six builtin themes did not resolve six distinct previews')
            missing_theme = 'stellae_sakura'
            missing = [directory / ('color_scheme_' + missing_theme + '.png')
                       for directory in (profile / 'preview', installation / 'data/preview')
                       if (directory / ('color_scheme_' + missing_theme + '.png')).is_file()]
            saved = [(path, path.read_bytes(), path.stat()) for path in missing]
            require(saved, 'The fixture has no removable skin preview')
            try:
                for path in missing:
                    path.unlink()
                settings.select_theme(appearance, themes,
                                      theme_labels.index(palettes['reference_gray']['name']))
                settings.select_theme(appearance, themes,
                                      theme_labels.index(palettes[missing_theme]['name']))
                require(settings.preview_bitmap(appearance, required=False) == 0,
                        'A missing skin preview retained its previous bitmap')
                require(settings.preview_bitmap(appearance, FONT_PREVIEW) == font_bitmap,
                        'A missing skin preview cleared the independent font preview')
            finally:
                for path, content, stat in saved:
                    path.write_bytes(content)
                    os.utime(path, ns=(stat.st_atime_ns, stat.st_mtime_ns))
            report['skinPreviewAssetSha256'] = skin_hashes
            report['sixBuiltinsAndCustomThemeVisible'] = True
            report['failedAndMissingSkinPreviewClearedOnlyItself'] = True
            report['previewsUpdatedIndependently'] = True
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


def apply_through_settings(installation, profile, initial_font, replacement_font, report):
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
            clock = next_configuration_second(profile, report, 'native font OK: ' + replacement_font)
            start = time.monotonic()
            settings.accept(appearance)
            require(process.wait(timeout=90) == 0, 'Native settings did not apply the replacement font')
            record_configuration_write(profile, clock)
            report['applyMilliseconds'] = round((time.monotonic() - start) * 1000)
            report['nativeSettingsReplacementFont'] = replacement_font
        finally:
            if process.poll() is None:
                process.kill()


def apply_theme_through_settings(installation, profile, theme, report, preceding_theme=None):
    import yaml

    palettes = compiled_themes(profile)
    expected_name = palettes[theme]['name']
    deployer = installation / 'StellaeDeployer.exe'
    with subprocess.Popen([str(deployer)], cwd=installation, stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL) as process:
        try:
            settings = SettingsDialog(process)
            switcher, _ = settings.wait_for(SCHEMA_LIST)
            settings.accept(switcher)
            appearance, combo = settings.wait_for(FONT_COMBO)
            font_index = settings.send(combo, CB_GETCURSEL)
            font_bitmap = settings.preview_bitmap(appearance, FONT_PREVIEW)
            themes, names = settings.theme_items(appearance)
            if preceding_theme:
                settings.select_theme(appearance, themes,
                                      names.index(palettes[preceding_theme]['name']))
            settings.select_theme(appearance, themes, names.index(expected_name))
            settings.preview_bitmap(appearance)
            require(settings.preview_bitmap(appearance, FONT_PREVIEW) == font_bitmap and
                    settings.send(combo, CB_GETCURSEL) == font_index,
                    'A theme-only selection changed the independent font choice or preview')
            settings.verify_preview_layout(appearance, report)
            clock = next_configuration_second(profile, report, 'native theme OK: ' + theme)
            start = time.monotonic()
            settings.accept(appearance)
            require(process.wait(timeout=90) == 0, 'The native theme selection did not apply')
            record_configuration_write(profile, clock)
            report['applyMilliseconds'] = round((time.monotonic() - start) * 1000)
            compiled = yaml.safe_load((profile / 'build/stellae.yaml').read_text('utf-8-sig'))
            require(compiled['style']['color_scheme'] == theme,
                    'The compiled appearance did not select the requested theme')
            require(compiled['style']['color_scheme_dark'] == theme,
                    'An aligned dark theme did not follow the selected normal theme')
            report['themeId'] = theme
            report['normalAndAlignedDarkTheme'] = theme
            return {key: int(palettes[theme][key]) & 0xffffffff for key in STYLE_COLORS}
        finally:
            if process.poll() is None:
                process.kill()


def verify_custom_font_defaults(installation, profile, report):
    """Use fixed CI-only custom values, then restore the fixture configuration."""
    import yaml

    custom = profile / 'stellae.custom.yaml'
    original = custom.read_bytes()
    custom_stack = 'Microsoft YaHei, Noto Sans CJK TC'
    deployer = installation / 'StellaeDeployer.exe'
    baseline_saved = []

    def compile_appearance():
        subprocess.run([str(deployer), '/deploy-appearance'], cwd=installation,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                       check=True, timeout=90)

    def style():
        return yaml.safe_load((profile / 'build/stellae.yaml').read_text(encoding='utf-8-sig'))['style']

    def write_custom(content, operation):
        clock = next_configuration_second(profile, report, operation)
        custom.write_bytes(content)
        atime = custom.stat().st_atime_ns
        # Stay in the middle of the synthetic timestamp second. Conversion
        # between filesystem/system clocks can straddle an exact boundary.
        os.utime(custom, ns=(atime, clock['readySecond'] * 1_000_000_000 + 500_000_000))
        record_configuration_write(profile, clock)

    def remove_baseline_dark():
        changed = []
        for directory in (installation / 'data', profile):
            for filename in ('stellae.yaml', 'stellae_bundle_appearance.yaml',
                             'rymcp_candidate_font.yaml', 'stellae_candidate_font.yaml',
                             'stellae/appearance.yaml'):
                path = directory / filename
                if not path.is_file():
                    continue
                raw, stat = path.read_bytes(), path.stat()
                # The upstream baseline uses tabs immediately before comments;
                # normalize that separator only in the stricter parser's copy.
                baseline = yaml.safe_load(raw.replace(b'\t#', b' #')) or {}
                removed = False
                for scope in (baseline, baseline.get('patch', {}),
                              baseline.get('weasel', {})):
                    if not isinstance(scope, dict):
                        continue
                    if 'style/color_scheme_dark' in scope:
                        scope.pop('style/color_scheme_dark')
                        removed = True
                    if isinstance(scope.get('style'), dict) and 'color_scheme_dark' in scope['style']:
                        scope['style'].pop('color_scheme_dark')
                        removed = True
                if removed:
                    baseline_saved.append((path, raw, stat))
                    clock = next_configuration_second(profile, report, 'remove fixture baseline dark: ' + filename)
                    path.write_text(yaml.safe_dump(baseline, allow_unicode=True, sort_keys=False),
                                    encoding='utf-8')
                    os.utime(path, ns=(stat.st_atime_ns,
                                      clock['readySecond'] * 1_000_000_000 + 500_000_000))
                    changed.append(('shared/' if directory == installation / 'data' else 'user/') + filename)
        require(changed, 'The absent dark-theme fixture removed no inherited baseline')
        report['absentDarkFixtureBaselineSources'] = changed

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
                settings.preview_bitmap(appearance, FONT_PREVIEW)
                report['customFontPreviewBitmapPresent'] = True
                if default:
                    settings.select_font_by_keyboard(appearance, combo,
                                                     font_item(items, 'Microsoft YaHei'))
                else:
                    themes, names = settings.theme_items(appearance)
                    palettes = compiled_themes(profile)
                    current = settings.send(themes, LB_GETCURSEL)
                    selected = names.index(palettes['stellae_night']['name'])
                    if selected == current:
                        selected = names.index(palettes['stellae_sakura']['name'])
                    settings.select_theme(appearance, themes, selected)
                clock = next_configuration_second(
                    profile, report, 'custom fixture Default OK' if default else 'unrelated theme OK')
                settings.accept(appearance)
                require(process.wait(timeout=90) == 0, 'The custom-font settings did not apply')
                record_configuration_write(profile, clock)
            finally:
                if process.poll() is None:
                    process.kill()

    try:
        data = yaml.safe_load(original)
        patch = data.setdefault('patch', {})
        patch['style/font_face'] = custom_stack
        patch['style/label_font_face'] = custom_stack
        patch['style/comment_font_face'] = 'Consolas'
        write_custom(yaml.safe_dump(data, allow_unicode=True, sort_keys=False).encode('utf-8'),
                     'write inherited fallback fixture')
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
        write_custom(yaml.safe_dump(data, allow_unicode=True, sort_keys=False).encode('utf-8'),
                     'write distinct fallback fixture')
        compile_appearance()
        configure(True)
        distinct = style()
        require(distinct['font_face'] == 'Microsoft YaHei' and
                distinct['label_font_face'] == distinct_label and
                distinct['comment_font_face'] == 'Consolas',
                'Default removed a distinct fallback stack sharing the same primary font')
        report['defaultPreservedDistinctSamePrimaryFallback'] = True
        patch['style/color_scheme_dark'] = CUSTOM_THEME
        write_custom(yaml.safe_dump(data, allow_unicode=True, sort_keys=False).encode('utf-8'),
                     'write distinct custom dark-theme fixture')
        compile_appearance()
        configure(False)
        require(style()['color_scheme_dark'] == CUSTOM_THEME,
                'A normal theme change overwrote a distinct custom dark theme')
        report['distinctCustomDarkThemePreserved'] = True
        # Rime's native YAML emitter drops null-valued map entries when saving
        # unrelated settings. A null deletion patch therefore cannot represent
        # persistent absence over a baseline that still defines this key.
        patch.pop('style/color_scheme_dark', None)
        remove_baseline_dark()
        write_custom(yaml.safe_dump(data, allow_unicode=True, sort_keys=False).encode('utf-8'),
                     'write absent dark-theme fixture')
        compile_appearance()
        require('color_scheme_dark' not in style(),
                'The absent dark-theme fixture still has a compiled dark selection')
        with effective_dark_reader(installation / 'rime.dll', installation / 'data', profile,
                                   installation / 'AppearanceFixtureLogs') as read_dark:
            require(read_dark() is None,
                    'Native CustomSettings did not observe the genuinely absent dark selection')
            configure(False)
            require('color_scheme_dark' not in style() and read_dark() is None,
                    'A normal theme change invented a genuinely absent dark selection')
        report['absentDarkVerifiedThroughNativeCustomSettings'] = True
        report['absentDarkThemeNotInvented'] = True
    finally:
        for path, raw, stat in baseline_saved:
            path.write_bytes(raw)
            os.utime(path, ns=(stat.st_atime_ns, stat.st_mtime_ns))
            require(path.read_bytes() == raw and path.stat().st_mtime_ns == stat.st_mtime_ns,
                    'A disposable fixture baseline did not restore exactly')
        write_custom(original, 'restore original fixture configuration')
        compile_appearance()


def digest(path):
    with path.open('rb') as stream:
        return file_digest(stream, 'sha256').hexdigest()


def scheme_snapshot(installation, profile):
    entries = {}
    folders = {'compiled': profile / 'build', 'shared': installation / 'data'}
    for category, folder in folders.items():
        for path in folder.rglob('*'):
            if path.is_file() and path.name != 'stellae.yaml':
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
        initial_palette = compiled_themes(profile)['reference_gray']
        require(all(getattr(before, key) == (int(initial_palette[key]) & 0xffffffff)
                    for key in STYLE_COLORS),
                'The initial candidate frame did not use the retained gray palette')

        # Leave a deterministic reason for a *full* deploy to recompile, even
        # if the GitHub VM copied every dictionary with the same timestamp.
        default = installation / 'data/default.yaml'
        default_stat = default.stat()
        os.utime(default, ns=(default_stat.st_atime_ns, default_stat.st_mtime_ns + 10_000_000_000))
        files_before = scheme_snapshot(installation, profile)
        appearance_before = digest(profile / 'build/stellae.yaml')
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
        apply_through_settings(installation, profile, initial_font, 'Microsoft YaHei', default_report)
        default_frame, offset = wait_for_frame(trace, args.server_pid, offset, 'Microsoft YaHei')
        require((before.window, before.composition, before.selected, before.count) ==
                (default_frame.window, default_frame.composition,
                 default_frame.selected, default_frame.count),
                'Applying Default changed the live candidate window or draft')
        report['defaultApply'] = default_report
        report['defaultFrame'] = asdict(default_frame)
        report['phase'] = 'native appearance-only apply'
        apply_through_settings(installation, profile, 'Microsoft YaHei', replacement_font, report)

        # Observe the real repaint before sending any further IPC request.
        report['phase'] = 'repaint and compare'
        after, _ = wait_for_frame(trace, args.server_pid, offset, replacement_font)
        report['after'] = asdict(after)
        require((before.window, before.composition, before.selected, before.count) ==
                (after.window, after.composition, after.selected, after.count),
                'The pre-existing candidate window or its draft changed during appearance reload')
        offset = len(read_frames(trace))
        report['phase'] = 'apply each builtin theme without changing the live draft'
        theme_results = []
        # Start with a different theme so each native OK has an actual change.
        for theme in (*BUILTIN_THEMES[1:], BUILTIN_THEMES[0]):
            theme_report = {}
            colors = apply_theme_through_settings(installation, profile, theme, theme_report)
            themed, offset = wait_for_frame(trace, args.server_pid, offset,
                                            replacement_font, colors)
            require((before.window, before.composition, before.selected, before.count) ==
                    (themed.window, themed.composition, themed.selected, themed.count),
                    'A theme change altered the retained candidate window or composition')
            theme_report['paintedFrame'] = asdict(themed)
            theme_report['actualPaintStyleColorsMatched'] = True
            theme_results.append(theme_report)
        report['themeApplications'] = theme_results
        report['sixThemesPreservedSameLiveDraft'] = True
        round_trip = {}
        apply_theme_through_settings(installation, profile, 'reference_gray', round_trip,
                                     preceding_theme='stellae_sakura')
        report['themeRoundTripReturnedToInitialBeforeOK'] = round_trip
        files_after = scheme_snapshot(installation, profile)
        changed = sorted(name for name in set(files_before) | set(files_after)
                         if files_before.get(name) != files_after.get(name))
        report['schemeFilesChecked'] = len(files_before)
        report['changedSchemeFiles'] = changed
        require(not changed, 'Appearance changed scheme or dictionary artifacts')
        require(digest(profile / 'build/stellae.yaml') != appearance_before,
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
    require(scheme_snapshot(installation, profile) == files_before,
            'The custom settings fixtures did not restore all scheme resources and timestamps')
    report['customFixturesPreservedSchemeResources'] = True


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
