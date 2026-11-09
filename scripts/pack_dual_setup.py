#!/usr/bin/env python3
"""Pack the autonomous CH32 read-only setup asset; never access hardware."""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import zlib

FLASH_BYTES = 4 * 1024 * 1024
IMAGE_OFFSET = 4096


def pack(image: bytes) -> bytes:
    if not image or len(image) % 512 or len(image) > FLASH_BYTES - IMAGE_OFFSET:
        raise ValueError('Both-role setup image must fit the specified 4 MiB SPI Flash')
    header = struct.pack('<8sIII', b'WKDUAL01', 1, len(image), zlib.crc32(image))
    return (header + struct.pack('<I', zlib.crc32(header))).ljust(IMAGE_OFFSET, b'\xff') + image


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('image', type=Path); p.add_argument('output', type=Path)
    a = p.parse_args(); data = a.image.read_bytes(); asset = pack(data)
    with a.output.open('xb') as f:
        f.write(asset)
    a.output.with_suffix('.json').write_text(json.dumps(dict(
        format='WKDUAL01', imageBytes=len(data), assetBytes=len(asset), flashCapacity=FLASH_BYTES,
        freeBytes=FLASH_BYTES-len(asset), imageSHA256=hashlib.sha256(data).hexdigest(),
        assetSHA256=hashlib.sha256(asset).hexdigest(), imageCRC32=f'{zlib.crc32(data):08x}',
        independentlyAvailableOnBothPorts=True, flashed=False), indent=2)+'\n')
    print(f'DUAL_SETUP_CAPACITY_PASS asset_bytes={len(asset)} limit={FLASH_BYTES} not_flashed=true')


if __name__ == '__main__':
    main()
