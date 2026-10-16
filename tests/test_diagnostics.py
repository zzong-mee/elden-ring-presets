import importlib.util
from pathlib import Path
import struct
import unittest

spec = importlib.util.spec_from_file_location("diagnostics", Path(__file__).resolve().parents[1] / "tools/diagnose_1171.py")
diag = importlib.util.module_from_spec(spec)
spec.loader.exec_module(diag)


def pe_fixture(duplicate=False, displacement=None):
    b = bytearray(2048)
    b[:2] = b"MZ"
    struct.pack_into("<I", b, 0x3C, 0x80)
    b[0x80:0x84] = b"PE\0\0"
    struct.pack_into("<HH", b, 0x84, 0x8664, 2)
    struct.pack_into("<H", b, 0x94, 0xF0)
    struct.pack_into("<H", b, 0x98, 0x20B)
    struct.pack_into("<I", b, 0x98 + 56, 0x4000)
    for offset, name, rva, raw in [(0x188, b".text", 0x1000, 0x400), (0x1B0, b".data", 0x2000, 0x600)]:
        b[offset:offset+len(name)] = name
        struct.pack_into("<IIII", b, offset+8, 0x200, rva, 0x200, raw)
    for offset in ([0x410, 0x450] if duplicate else [0x410]):
        delta = 0x2020 - (0x1000 + offset - 0x400 + 7) if displacement is None else displacement
        signature = b"\x48\x8b\x05" + struct.pack("<i", delta) + bytes.fromhex("48 85 c0 74 05 48 8b 40 58 c3 c3")
        b[offset:offset+len(signature)] = signature
    return b


class DiagnosticsTests(unittest.TestCase):
    def test_unique_signature_resolves_rva(self):
        self.assertEqual(diag.scan_pe(pe_fixture()), 0x2020)

    def test_duplicate_signature_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "found 2"):
            diag.scan_pe(pe_fixture(duplicate=True))

    def test_missing_signature_is_rejected(self):
        b = pe_fixture(); b[0x410] = 0
        with self.assertRaisesRegex(ValueError, "found 0"):
            diag.scan_pe(b)

    def test_invalid_target_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "outside image"):
            diag.scan_pe(pe_fixture(displacement=0x70000000))

    def test_truncated_headers_are_rejected(self):
        with self.assertRaises(ValueError):
            diag.scan_pe(pe_fixture()[:300])

    def test_truncated_data_is_rejected(self):
        with self.assertRaises(ValueError):
            diag.scan_pe(pe_fixture()[:1200])

    def test_snapshot_uses_new_layout(self):
        memory = {}
        def put(address, fmt, value):
            memory[address] = struct.pack(fmt, value)
        put(0x100000 + 0x2020, '<Q', 0x200000)
        put(0x200008, '<Q', 0x300000)
        put(0x300530, '<Q', 0x400000)
        for name, offset in diag.STATS.items():
            put(0x300000 + offset, '<I', 150 if name == 'LEVEL' else 20)
        for name, offset in diag.GEAR.items():
            put(0x300000 + offset, '<I', offset)
        for i in range(12):
            put(0x400010 + i*8, '<I', i)
        def read(addr, size):
            value = memory[addr]
            self.assertEqual(len(value), size)
            return value
        result = diag.collect_snapshot(read, 0x100000, 0x2020)
        self.assertEqual(len(result['gear']), 14)
        self.assertEqual(result['gear']['Weapon_R1'], 0x39C)
        self.assertEqual(result['stats']['LEVEL'], 150)
        self.assertEqual(result['magic'], list(range(12)))
        put(0x300068, '<I', 0xFFFFFFFF)
        with self.assertRaisesRegex(ValueError, 'range checks'):
            diag.collect_snapshot(read, 0x100000, 0x2020)
        put(0x200008, '<Q', 0)
        with self.assertRaisesRegex(ValueError, 'pointer unavailable'):
            diag.collect_snapshot(read, 0x100000, 0x2020)

    def test_four_preset_configuration(self):
        import json
        config = json.loads((Path(__file__).resolve().parents[1] / 'examples/loadout-manager/keyboard_hotkeys.json').read_text())
        self.assertEqual(len(config), 8)
        for i in range(1,5):
            self.assertEqual(config[f'save_preset_{i}'], [f'f{i}'])
            self.assertEqual(config[f'load_preset_{i}'], [str(i)])

if __name__ == '__main__':
    unittest.main()
