# SPDX-License-Identifier: GPL-3.0-only
import argparse
from pathlib import Path
import re
import subprocess


def production_code(root, baseline):
    tray = root / 'WeaselServer'
    # Replace the Win32/ATL boundary with the in-process shell and HWND fixture.
    code = '\n'.join((tray / name).read_text(encoding='utf-8-sig')
                     for name in ('WeaselTrayIcon.h', 'WeaselTrayIcon.cpp'))
    code = re.sub(r'^#(?:include|pragma once).*$', '', code, flags=re.M)
    if not baseline:
        handler = (root / 'RimeWithWeasel/RimeWithWeasel.cpp').read_text(encoding='utf-8-sig')
        first = handler.index('void RimeWithWeaselHandler::SetOption(')
        last = handler.index('\n}', first)
        code += '\n' + handler[first:last + 2]
    return code


def run(root, work, compiler, baseline):
    work.mkdir(parents=True, exist_ok=True)
    (work / 'production.h').write_text(production_code(root, baseline), encoding='utf-8')
    fixture = Path(__file__).with_name('TrayRefreshTests.cpp').resolve()
    name = Path(compiler).stem.lower()
    exe = work / 'tray-test.exe'
    if name in ('cl', 'clang-cl'):
        cmd = [compiler, '/nologo', '/EHsc', '/std:c++17', '/utf-8',
               '/DFIXTURE_BASELINE=' + str(int(baseline)), '/I' + str(work),
               str(fixture), '/Fe' + str(exe)]
    else:
        cmd = [compiler] + (['c++'] if name == 'zig' else [])
        cmd += ['-std=c++17', '-DFIXTURE_BASELINE=' + str(int(baseline)),
                '-I' + str(work), str(fixture), '-o', str(exe)]
    subprocess.run(cmd, cwd=work, check=True)
    subprocess.run([str(exe)], cwd=work, timeout=20, check=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--source-root', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--baseline-root', type=Path)
    parser.add_argument('--compiler', default='cl.exe')
    args = parser.parse_args()
    if args.baseline_root:
        run(args.baseline_root, args.output.resolve() / 'before', args.compiler, True)
    run(args.source_root, args.output.resolve() / 'after', args.compiler, False)
