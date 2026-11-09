#!/usr/bin/env python3
"""Pack a read-only Setup image for the existing installer partition. Never flash."""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import zlib

IMAGE_OFFSET = 4096
PARTITION_BYTES = 12 * 1024 * 1024


def pack(image: bytes) -> bytes:
    if not image or len(image) % 512 or len(image) > PARTITION_BYTES - IMAGE_OFFSET:
        raise ValueError('Setup image must be nonempty, sector aligned and fit installer partition')
    header = struct.pack('<8sIII', b'WKSETUP1', 1, len(image), zlib.crc32(image))
    header += struct.pack('<I', zlib.crc32(header))
    return header.ljust(IMAGE_OFFSET, b'\xff') + image


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('image', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    if args.image.resolve() == args.output.resolve():
        parser.error('output must not replace input')
    image = args.image.read_bytes()
    asset = pack(image)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    # A repeated build must explicitly choose a fresh output; preserve existing artifacts.
    with args.output.open('xb') as stream:
        stream.write(asset)
    manifest = dict(format=1, partition='installer', partition_offset='0x400000',
                    partition_bytes=PARTITION_BYTES, image_offset=IMAGE_OFFSET,
                    image_bytes=len(image), image_crc32=f'{zlib.crc32(image):08x}',
                    image_sha256=hashlib.sha256(image).hexdigest(), asset_bytes=len(asset),
                    asset_sha256=hashlib.sha256(asset).hexdigest(), flashed=False)
    args.output.with_suffix('.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps(manifest))


if __name__ == '__main__':
    main()
