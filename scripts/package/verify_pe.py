"""Inspect Windows images without executing them.

SPDX-License-Identifier: GPL-3.0-only
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PureWindowsPath
import re
import struct


def inspect(path: Path):
    raw = path.read_bytes()

    def unpack(fmt, offset):
        size = struct.calcsize(fmt)
        if offset < 0 or offset + size > len(raw):
            raise ValueError("truncated PE structure")
        return struct.unpack_from(fmt, raw, offset)

    if raw[:2] != b"MZ":
        raise ValueError("missing DOS signature")
    pe, = unpack("<I", 0x3C)
    if raw[pe:pe + 4] != b"PE\0\0":
        raise ValueError("missing PE signature")
    machine, section_count = unpack("<HH", pe + 4)
    optional_size, = unpack("<H", pe + 20)
    optional = pe + 24
    magic, = unpack("<H", optional)
    if magic not in {0x10B, 0x20B}:
        raise ValueError("unsupported optional header")
    directory = optional + (96 if magic == 0x10B else 112)
    sections = []
    for index in range(section_count):
        offset = optional + optional_size + index * 40
        virtual_size, address, size, file_offset = unpack("<IIII", offset + 8)
        sections.append((address, max(virtual_size, size), file_offset, size))

    def rva(address, length=1):
        for start, virtual_size, file_offset, file_size in sections:
            if start <= address < start + virtual_size:
                delta = address - start
                if delta + length > file_size or file_offset + delta + length > len(raw):
                    raise ValueError("PE address outside stored section")
                return file_offset + delta
        if address + length <= optional + optional_size:
            return address
        raise ValueError("unmapped PE address")

    def cstring(offset, limit=4096):
        end = raw.find(b"\0", offset, min(len(raw), offset + limit))
        if end < 0:
            raise ValueError("unterminated PE string")
        return raw[offset:end].decode("utf-8", errors="replace")

    imports = []
    import_address, import_size = unpack("<II", directory + 8)
    if import_address:
        offset = rva(import_address, 20)
        for index in range(min(2048, max(1, import_size // 20 + 1))):
            descriptor = unpack("<IIIII", offset + index * 20)
            if not any(descriptor):
                break
            imports.append(cstring(rva(descriptor[3])).lower())
        else:
            raise ValueError("unterminated PE import table")

    debug_records = []
    debug_address, debug_size = unpack("<II", directory + 6 * 8)
    if debug_address:
        offset = rva(debug_address, debug_size)
        if debug_size % 28:
            raise ValueError("invalid debug directory length")
        for index in range(debug_size // 28):
            entry = unpack("<IIHHIIII", offset + index * 28)
            if entry[4] != 2:
                continue
            length, pointer = entry[5], entry[7]
            if pointer + length > len(raw) or length < 4:
                raise ValueError("invalid CodeView record")
            signature = raw[pointer:pointer + 4]
            if signature == b"RSDS":
                text_offset = pointer + 24
            elif signature == b"NB10":
                text_offset = pointer + 16
            else:
                raise ValueError("unsupported CodeView format")
            pdb_path = cstring(text_offset, length - (text_offset - pointer))
            basename = PureWindowsPath(pdb_path.replace("/", "\\")).name
            neutral = pdb_path == basename and bool(basename) and not re.search(r"[:\\/]", pdb_path)
            debug_records.append({
                "format": signature.decode("ascii"), "pdbFile": basename,
                "pathKind": "basename" if neutral else "upstream-path",
                "pathSHA256": hashlib.sha256(pdb_path.encode("utf-8")).hexdigest(),
            })
    return {"machine": hex(machine), "imports": sorted(set(imports)), "codeView": debug_records}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    root = args.root.resolve()
    if not root.is_dir():
        raise SystemExit("PE input directory does not exist")
    images = sorted(p for p in root.rglob("*") if p.is_file() and p.suffix.lower() in {".exe", ".dll", ".ime"})
    if not images:
        raise SystemExit("No Windows images found")
    entries, errors = [], []
    for path in images:
        relative = path.relative_to(root).as_posix()
        try:
            result = inspect(path)
            first_party = path.name.lower().startswith("stellae") or path.name.lower() == "rime.dll"
            if first_party and any(record["pathKind"] != "basename" for record in result["codeView"]):
                errors.append(f"Non-neutral CodeView path: {relative}")
            for dependency in result["imports"]:
                if dependency == "rime.dll" and not (path.parent / "rime.dll").is_file():
                    errors.append(f"Missing sibling engine: {relative}")
            entries.append({"path": relative, "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), **result})
        except (ValueError, struct.error) as error:
            errors.append(f"Invalid image {relative}: {error}")
    report = {"format": "stellae-pe-inspection-v1", "images": entries, "errors": errors, "passed": not errors}
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8", newline="\n")
    print(json.dumps({"images": len(entries), "errors": errors, "passed": not errors}))
    if errors:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
