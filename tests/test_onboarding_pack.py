"""Synthetic autonomous installer format tests. No hardware or app launch."""
import importlib.util
from pathlib import Path
import struct
import unittest
import zlib

spec = importlib.util.spec_from_file_location('dual_setup_pack', Path(__file__).resolve().parents[1]/'scripts/pack_dual_setup.py')
pack = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pack)


class OnboardingPackTests(unittest.TestCase):
    def test_exact_header_and_original_image(self):
        image = bytes(range(256))*4
        asset = pack.pack(image)
        magic,version,n,checksum,header = struct.unpack('<8sIIII',asset[:24])
        self.assertEqual((magic,version,n,checksum),(b'WKDUAL01',1,len(image),zlib.crc32(image)))
        self.assertEqual(header,zlib.crc32(asset[:20]))
        self.assertEqual(asset[4096:],image)

    def test_four_mebibyte_capacity_boundary(self):
        image = bytes(pack.FLASH_BYTES-pack.IMAGE_OFFSET)
        self.assertEqual(len(pack.pack(image)),pack.FLASH_BYTES)
        with self.assertRaises(ValueError): pack.pack(image+bytes(512))

    def test_empty_and_unaligned_refused(self):
        for image in [b'',b'x',bytes(513)]:
            with self.subTest(n=len(image)),self.assertRaises(ValueError): pack.pack(image)


if __name__=='__main__': unittest.main()
