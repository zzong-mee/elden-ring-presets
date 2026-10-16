#!/usr/bin/env python3
"""Build a separate diagnostic EXE from the user's PyInstaller runtime (Python 3.13).

The original executable is never modified. No original application entry point is run.
Retains the supplied runtime/dependency archive, replacing only its main code object.
"""
import argparse
import base64
import json
import hashlib
import marshal
from pathlib import Path
import struct
import sys
import zlib

MAGIC = b'MEI\014\013\012\013\016'
EXPECTED_SHA256 = '31a132aceee81a1e2b71fc4ba1d149e074844b36a7c9d029fd1f1d10813727f1'


def build(original: Path, destination: Path, source: Path, payload_json=None):
    if sys.version_info[:2] != (3,13):
        raise RuntimeError('Use Python 3.13 to match the supplied runtime')
    data = original.read_bytes()
    if hashlib.sha256(data).hexdigest() != EXPECTED_SHA256:
        raise ValueError('Unexpected original executable; inspect packaging before reuse')
    cookie = data.rfind(MAGIC)
    _, size, toc_offset, toc_size, version, library = struct.unpack('!8sIIII64s', data[cookie:cookie+88])
    if version != 313 or cookie + 88 != len(data):
        raise ValueError('Unexpected PyInstaller archive layout')
    start = cookie + 88 - size
    toc = data[start+toc_offset:start+toc_offset+toc_size]
    if payload_json is None:
        code = marshal.dumps(compile(source.read_text(encoding='utf-8'), 'diagnose_1171.py', 'exec'))
    else:
        payload=json.loads(payload_json.read_text(encoding='utf-8'))
        packed=base64.b64decode(payload['payload'])
        if hashlib.sha256(packed).hexdigest()!=payload['compressed_sha256']:
            raise ValueError('Payload checksum mismatch')
        code=zlib.decompress(packed)
        if len(code)!=payload['raw_size'] or payload['python_version']!=313:
            raise ValueError('Unexpected payload metadata')
    chunks = bytearray(); new_toc = bytearray(); pos = 0; replaced = 0
    while pos < len(toc):
        length, offset, compressed, raw, flag, kind = struct.unpack('!IIIIBc', toc[pos:pos+18])
        if length < 18 or pos+length > len(toc):
            raise ValueError('Malformed archive directory')
        name = toc[pos+18:pos+length].rstrip(b'\0')
        payload = data[start+offset:start+offset+compressed]
        if name == b'main' and kind == b's':
            payload = zlib.compress(code, 9) if flag else code
            raw = len(code); replaced += 1
        name_bytes = name + b'\0'
        entry_length = (18 + len(name_bytes) + 15) // 16 * 16
        new_toc += struct.pack('!IIIIBc', entry_length, len(chunks), len(payload), raw, flag, kind)
        new_toc += name_bytes + b'\0' * (entry_length - 18 - len(name_bytes))
        chunks += payload
        pos += length
    if replaced != 1:
        raise ValueError('Expected exactly one main entry')
    new_cookie = struct.pack('!8sIIII64s', MAGIC, len(chunks)+len(new_toc)+88,
                             len(chunks), len(new_toc), version, library)
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(data[:start] + chunks + new_toc + new_cookie)
    # Verify that the resulting directory points at precisely our own code.
    result = destination.read_bytes(); end = result.rfind(MAGIC)
    _, total, off, length, _, _ = struct.unpack('!8sIIII64s', result[end:end+88])
    base = end+88-total; directory = result[base+off:base+off+length]; p = 0
    while p < len(directory):
        n, at, packed, raw, flag, kind = struct.unpack('!IIIIBc', directory[p:p+18])
        if directory[p+18:p+n].rstrip(b'\0') == b'main':
            payload = result[base+at:base+at+packed]
            assert (zlib.decompress(payload) if flag else payload) == code
        p += n
    print('Built Windows entry point; Windows runtime execution remains untested:', destination)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('original', type=Path)
    parser.add_argument('destination', type=Path)
    parser.add_argument('--source', type=Path, default=Path(__file__).with_name('diagnose_1171.py'))
    parser.add_argument('--payload-json',type=Path)
    args = parser.parse_args()
    build(args.original, args.destination, args.source,args.payload_json)
