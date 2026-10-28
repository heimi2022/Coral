"""Check bank placement, address inversion and isolated mapping changes."""

from pathlib import Path
import tempfile
import unittest

from profile_matrix_dram_banks import (
    CANDIDATE, COMPARISONS, access_row_changes, encoder, mapping_config,
    placement, read_config, tile_addresses,
)
from profile_matrix_dram_commands import address_decoder


BASE = Path(__file__).with_name("CORAL_DDR4_32GBps_interleaved.ini")


class BankMappingTest(unittest.TestCase):
    def test_address_roundtrip_including_rank_and_row_boundaries(self):
        addresses = [0, 63, 64, 0x1ffff, 0x20000, 0x3ffff, 0x40000,
                     0x80000000, 0x80010000, 0x80021000, 0x8013ffc0,
                     (1 << 34) - 64]
        with tempfile.TemporaryDirectory() as temporary:
            for mapping in COMPARISONS:
                config = mapping_config(BASE, mapping, Path(temporary) / "map.ini")
                decode, _, _ = address_decoder(config)
                encode = encoder(config)
                for address in addresses:
                    with self.subTest(mapping=mapping, address=hex(address)):
                        self.assertEqual(encode(decode(address)), address // 64 * 64)
                with self.assertRaises(ValueError):
                    encode((0, 2, 0, 0, 0, 0))

    def test_only_mapping_changes_and_invalid_map_preserves_destination(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "map.ini"
            mapping_config(BASE, CANDIDATE, output)
            before, after = read_config(BASE), read_config(output)
            self.assertEqual(before.sections(), after.sections())
            self.assertEqual([(s, k) for s in before.sections() for k in before[s]
                              if before[s][k] != after[s][k]],
                             [("system", "address_mapping")])
            contents = output.read_bytes()
            with self.assertRaises(ValueError):
                mapping_config(BASE, "rochrababgxx", output)
            self.assertEqual(output.read_bytes(), contents)
            with self.assertRaises(ValueError):
                mapping_config(BASE, CANDIDATE, BASE)

    def test_b_and_c_tile_bank_group_distribution(self):
        b = tile_addresses(dict(base=0x80010000, rows=64, cols=64,
                                elem_bytes_log2=0, stride=128))
        c = tile_addresses(dict(base=0x80040000, rows=64, cols=64,
                                elem_bytes_log2=2, stride=2048))
        expected = [(8, 2, 4, 4), (2, 2, 16, 4), (1, 1, 16, 4)]
        with tempfile.TemporaryDirectory() as temporary:
            for mapping, want in zip(COMPARISONS, expected):
                config = mapping_config(BASE, mapping, Path(temporary) / "map.ini")
                decode, _, _ = address_decoder(config)
                bp, cp = placement(b, decode), placement(c, decode)
                with self.subTest(mapping=mapping):
                    self.assertEqual((bp["banks"], bp["rank_bank_groups"],
                                      cp["banks"], cp["rank_bank_groups"]), want)
                    self.assertEqual((bp["beats"], cp["beats"]), (64, 256))

    def test_row_changes_keep_banks_and_ranks_separate(self):
        decode, _, _ = address_decoder(BASE)
        encode = encoder(BASE)

        def access(rank, bank, row, kind, role):
            return dict(byte_address=encode((0, rank, 0, bank, row, 0)),
                        kind=kind, role=role)

        accesses = [access(0, 0, 1, "write", "C"),
                    access(1, 0, 2, "read", "B"),
                    access(0, 1, 2, "read", "B"),
                    access(0, 0, 2, "read", "B"),
                    access(0, 0, 2, "read", "B"),
                    access(0, 0, 3, "write", "C"),
                    access(0, 0, 4, "read", "A")]
        self.assertEqual(access_row_changes(accesses, decode),
                         dict(total=3, write_to_read=2, c_write_to_b_read=1))

    def test_partial_or_unaligned_tiles_are_rejected(self):
        tile = dict(base=0x80010000, rows=64, cols=64, elem_bytes_log2=0, stride=128)
        for change in (dict(base=1), dict(cols=63), dict(stride=127)):
            with self.subTest(change=change), self.assertRaises(ValueError):
                tile_addresses(dict(tile, **change))


if __name__ == "__main__":
    unittest.main()
