#!/usr/bin/env python3
"""Read-only 1.17.1 diagnostics. Never writes to the game or changes offsets."""
from __future__ import annotations
import argparse
import ctypes as C
import hashlib
import json
import os
from pathlib import Path
import re
import struct
import sys

SOURCE_COMMIT = "7926205c5a2ed236dd31278c4f5579c964ceec35"
# TGA .cea GameDataMan AOB and Hero XML layouts at SOURCE_COMMIT.
PATTERN = re.compile(rb"\x48\x8b\x05....\x48\x85\xc0\x74\x05\x48\x8b\x40\x58\xc3\xc3", re.DOTALL)
GEAR = {"Weapon_L1": 0x398, "Weapon_R1": 0x39C, "Weapon_L2": 0x3A0,
        "Weapon_R2": 0x3A4, "Weapon_L3": 0x3A8, "Weapon_R3": 0x3AC,
        "Head": 0x3C8, "Armor": 0x3CC, "Gauntlets": 0x3D0, "Legs": 0x3D4,
        "Talisman_1": 0x3DC, "Talisman_2": 0x3E0,
        "Talisman_3": 0x3E4, "Talisman_4": 0x3E8}
STATS = {"VIGOR": 0x3C, "MIND": 0x40, "ENDURANCE": 0x44, "STRENGTH": 0x48,
         "DEXTERITY": 0x4C, "INTELLIGENCE": 0x50, "FAITH": 0x54, "ARCANE": 0x58,
         "LEVEL": 0x68}


def scan_pe(data) -> int:
    """Return the singleton-pointer RVA from one unique .text RIP-relative load."""
    if data[:2] != b"MZ" or len(data) < 64:
        raise ValueError("Not a PE executable")
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    if pe + 24 > len(data) or data[pe:pe+4] != b"PE\0\0":
        raise ValueError("Invalid PE header")
    machine, count = struct.unpack_from("<HH", data, pe + 4)
    optional_size = struct.unpack_from("<H", data, pe + 20)[0]
    if machine != 0x8664 or not 1 <= count <= 96 or optional_size < 64:
        raise ValueError("Expected x64 PE")
    optional = pe + 24
    if optional + optional_size > len(data) or struct.unpack_from("<H", data, optional)[0] != 0x20B:
        raise ValueError("Invalid PE32+ optional header")
    image_size = struct.unpack_from("<I", data, optional + 56)[0]
    sections = []
    for i in range(count):
        start = optional + optional_size + i * 40
        if start + 40 > len(data):
            raise ValueError("Truncated section header")
        name = data[start:start+8].rstrip(b"\0")
        virtual_size, rva, raw_size, offset = struct.unpack_from("<IIII", data, start + 8)
        if offset + raw_size > len(data):
            raise ValueError("Truncated section")
        sections.append((name, virtual_size, rva, raw_size, offset))
    hits = []
    for name, _, rva, size, offset in sections:
        if name != b".text":
            continue
        for hit in PATTERN.finditer(data, offset, offset + size):
            displacement = struct.unpack_from("<i", data, hit.start() + 3)[0]
            target = rva + hit.start() - offset + 7 + displacement
            if target < 0 or target + 8 > image_size:
                raise ValueError("Signature points outside image")
            if not any(v <= target and target + 8 <= v + max(vs, rs)
                       for _, vs, v, rs, _ in sections):
                raise ValueError("Signature target outside sections")
            hits.append(target)
    if len(hits) != 1:
        raise ValueError(f"Expected one GameDataMan signature, found {len(hits)}")
    return hits[0]


def collect_snapshot(read, module_base, rva):
    def ptr(address):
        value = struct.unpack("<Q", read(address, 8))[0]
        if not 0x10000 <= value < 0x800000000000:
            raise ValueError("Game pointer unavailable; load a character first")
        return value
    manager = ptr(module_base + rva)
    player = ptr(manager + 8)
    stats = {name: struct.unpack("<I", read(player + offset, 4))[0]
             for name, offset in STATS.items()}
    if not 1 <= stats["LEVEL"] <= 713 or not all(1 <= stats[k] <= 99 for k in STATS if k != "LEVEL"):
        raise ValueError("Player data failed range checks")
    gear = {name: struct.unpack("<I", read(player + offset, 4))[0]
            for name, offset in GEAR.items()}
    magic = ptr(player + 0x530)
    spells = [struct.unpack("<I", read(magic + 0x10 + i * 8, 4))[0] for i in range(12)]
    # A character transition invalidates even individually successful reads.
    if ptr(module_base + rva) != manager or ptr(manager + 8) != player:
        raise ValueError("Character changed during capture; retry")
    return {"stats": stats, "gear": gear, "magic": spells,
            "range_checks_passed": True,
            "note": "Readability and plausible values do not verify equip operations or DLC compatibility."}


def windows_snapshot():
    if os.name != "nt" or C.sizeof(C.c_void_p) != 8:
        raise RuntimeError("Use 64-bit Python on Windows")
    from ctypes import wintypes as W
    kernel = C.WinDLL("kernel32", use_last_error=True)
    class PROCESSENTRY32(C.Structure):
        _fields_ = [("size", W.DWORD), ("usage", W.DWORD), ("pid", W.DWORD),
                    ("heap", C.c_size_t), ("module", W.DWORD), ("threads", W.DWORD),
                    ("parent", W.DWORD), ("priority", W.LONG), ("flags", W.DWORD),
                    ("name", W.WCHAR * 260)]
    class MODULEENTRY32(C.Structure):
        _fields_ = [("size", W.DWORD), ("id", W.DWORD), ("pid", W.DWORD),
                    ("global_usage", W.DWORD), ("process_usage", W.DWORD),
                    ("base", C.c_void_p), ("length", W.DWORD), ("handle", W.HMODULE),
                    ("name", W.WCHAR * 256), ("path", W.WCHAR * 260)]
    kernel.CreateToolhelp32Snapshot.argtypes = [W.DWORD, W.DWORD]
    kernel.CreateToolhelp32Snapshot.restype = W.HANDLE
    kernel.CloseHandle.argtypes = [W.HANDLE]
    kernel.CloseHandle.restype = W.BOOL
    kernel.Process32FirstW.argtypes = [W.HANDLE, C.POINTER(PROCESSENTRY32)]
    kernel.Process32NextW.argtypes = kernel.Process32FirstW.argtypes
    kernel.Process32FirstW.restype = kernel.Process32NextW.restype = W.BOOL
    kernel.Module32FirstW.argtypes = [W.HANDLE, C.POINTER(MODULEENTRY32)]
    kernel.Module32FirstW.restype = W.BOOL
    kernel.OpenProcess.argtypes = [W.DWORD, W.BOOL, W.DWORD]
    kernel.OpenProcess.restype = W.HANDLE
    kernel.ReadProcessMemory.argtypes = [W.HANDLE, C.c_void_p, C.c_void_p, C.c_size_t, C.POINTER(C.c_size_t)]
    kernel.ReadProcessMemory.restype = W.BOOL
    invalid = C.c_void_p(-1).value
    snapshot = kernel.CreateToolhelp32Snapshot(2, 0)
    if snapshot == invalid:
        raise C.WinError(C.get_last_error())
    found = []
    anticheat = False
    try:
        entry = PROCESSENTRY32(); entry.size = C.sizeof(entry)
        ok = kernel.Process32FirstW(snapshot, C.byref(entry))
        while ok:
            name = entry.name.lower()
            if name == "eldenring.exe":
                found.append(entry.pid)
            if name.startswith("easyanticheat"):
                anticheat = True
            ok = kernel.Process32NextW(snapshot, C.byref(entry))
    finally:
        kernel.CloseHandle(snapshot)
    if len(found) != 1:
        raise RuntimeError(f"Expected one running eldenring.exe, found {len(found)}")
    snapshot = kernel.CreateToolhelp32Snapshot(0x18, found[0])
    if snapshot == invalid:
        raise C.WinError(C.get_last_error())
    try:
        module = MODULEENTRY32(); module.size = C.sizeof(module)
        if not kernel.Module32FirstW(snapshot, C.byref(module)):
            raise C.WinError(C.get_last_error())
        if module.name.lower() != "eldenring.exe":
            raise RuntimeError("Unexpected main module")
        image = Path(module.path)
        base = module.base
    finally:
        kernel.CloseHandle(snapshot)
    version = file_version(image)
    with image.open("rb") as f:
        data = f.read()
    rva = scan_pe(data)
    digest = hashlib.sha256(data).hexdigest()
    del data
    handle = kernel.OpenProcess(0x410, False, found[0])  # QUERY_INFORMATION | VM_READ only
    if not handle:
        raise C.WinError(C.get_last_error())
    def read(address, size):
        buffer = C.create_string_buffer(size)
        count = C.c_size_t()
        if not kernel.ReadProcessMemory(handle, address, buffer, size, C.byref(count)) or count.value != size:
            raise RuntimeError("ReadProcessMemory failed or returned a partial read")
        return buffer.raw
    try:
        # Ensure live signature and RIP target match the versioned disk image.
        with image.open("rb") as f:
            f.seek(0x3C); pe = struct.unpack("<I", f.read(4))[0]
            f.seek(pe + 8); timestamp = f.read(4)
        live_pe = struct.unpack("<I", read(base + 0x3C, 4))[0]
        if read(base + live_pe + 8, 4) != timestamp:
            raise RuntimeError("Disk/live executable headers differ")
        data = collect_snapshot(read, base, rva)
        return {"status": "read_only_snapshot", "exe_file_version": version,
                "target_app_version": "1.17.1", "app_version_independently_verified": False,
                "exe_sha256": digest, "game_data_rva": hex(rva),
                "anticheat_process_present": anticheat, **data,
                "write_support_verified": False, "tga_commit": SOURCE_COMMIT}
    finally:
        kernel.CloseHandle(handle)


def file_version(path):
    from ctypes import wintypes as W
    api = C.WinDLL("version", use_last_error=True)
    api.GetFileVersionInfoSizeW.argtypes = [W.LPCWSTR, C.POINTER(W.DWORD)]
    api.GetFileVersionInfoSizeW.restype = W.DWORD
    api.GetFileVersionInfoW.argtypes = [W.LPCWSTR, W.DWORD, W.DWORD, C.c_void_p]
    api.GetFileVersionInfoW.restype = W.BOOL
    api.VerQueryValueW.argtypes = [C.c_void_p, W.LPCWSTR, C.POINTER(C.c_void_p), C.POINTER(W.UINT)]
    api.VerQueryValueW.restype = W.BOOL
    dummy = W.DWORD(); size = api.GetFileVersionInfoSizeW(str(path), C.byref(dummy))
    if not size:
        raise C.WinError(C.get_last_error())
    buffer = C.create_string_buffer(size)
    if not api.GetFileVersionInfoW(str(path), 0, size, buffer):
        raise C.WinError(C.get_last_error())
    pointer = C.c_void_p(); length = W.UINT()
    if not api.VerQueryValueW(buffer, "\\", C.byref(pointer), C.byref(length)) or length.value < 52:
        raise RuntimeError("Missing executable version")
    values = struct.unpack("<13I", C.string_at(pointer, 52))
    if values[0] != 0xFEEF04BD:
        raise RuntimeError("Invalid version resource")
    return [values[2] >> 16, values[2] & 65535, values[3] >> 16, values[3] & 65535]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path("compatibility-report.json"))
    args = parser.parse_args()
    try:
        report = windows_snapshot()
        code = 0
    except (OSError, ValueError, RuntimeError, struct.error) as exc:
        report = {"status": "failed", "error": str(exc), "write_support_verified": False}
        code = 1
    args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    if sys.stdout is not None:
        print(json.dumps(report, indent=2))
    if getattr(sys, "frozen", False):
        from tkinter import messagebox
        if code == 0:
            messagebox.showinfo("Read-only diagnostic", "Read completed. This does not verify equipment changes.\nReport: " + str(args.output.resolve()))
        else:
            messagebox.showerror("Read-only diagnostic", report["error"] + "\nReport: " + str(args.output.resolve()))
    return code

if __name__ == "__main__":
    raise SystemExit(main())
