# SPDX-License-Identifier: GPL-3.0-only
import argparse
from pathlib import Path
import subprocess


def method(source, signature, indent=""):
    start = source.index(indent + signature)
    end_marker = "\n" + indent + "}"
    end = source.index(end_marker, start) + len(end_marker)
    return source[start:end] + "\n"


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--compiler", default="cl.exe")
    args = parser.parse_args()
    work = args.output.resolve()
    work.mkdir(parents=True, exist_ok=True)
    client = (args.source_root / "WeaselIPC/WeaselClientImpl.cpp").read_text("utf-8-sig")
    composition = (args.source_root / "WeaselTSF/Composition.cpp").read_text("utf-8-sig")
    server = (args.source_root / "WeaselIPCServer/WeaselServerImpl.cpp").read_text("utf-8-sig")
    channel = (args.source_root / "include/PipeChannel.h").read_text("utf-8-sig")
    (work / "position.inc").write_text(
        method(client, "void ClientImpl::UpdateInputPosition(")
        + method(client, "void Client::UpdateInputPosition(")
        + method(client, "void Client::UpdateModeInputPosition(")
        + method(composition, "void WeaselTSF::_PublishModePosition(")
        + method(server, "DWORD ServerImpl::OnUpdateInputPosition(")
        + method(server, "const char* PipeServer::_ReceiveRequest("), encoding="utf-8")
    (work / "transaction.inc").write_text(
        method(channel, "Outcome TransactOutcome(", "  "), encoding="utf-8")
    fixture = Path(__file__).with_name("InputPositionTests.cpp").resolve()
    exe = work / "input-position-test.exe"
    if Path(args.compiler).stem.lower() in ("cl", "clang-cl"):
        command = [args.compiler, "/nologo", "/EHsc", "/std:c++17", "/utf-8",
                   "/I" + str(work), str(fixture), "/Fe" + str(exe)]
    else:
        command = [args.compiler] + (["c++"] if Path(args.compiler).stem.lower() == "zig" else [])
        command += ["-std=c++17", "-I" + str(work), str(fixture), "-o", str(exe)]
    subprocess.run(command, cwd=work, check=True)
    subprocess.run([str(exe)], cwd=work, check=True, timeout=20)
