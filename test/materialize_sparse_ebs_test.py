import importlib.util
import os
import tempfile
import unittest
from pathlib import Path


SCRIPT = (
    Path(__file__).parent.parent
    / "patches"
    / "ubuntu"
    / "files"
    / "materialize-sparse-ebs.py"
)
SPEC = importlib.util.spec_from_file_location("materialize_sparse_ebs", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class MaterializeSparseEbsTest(unittest.TestCase):
    def test_allocated_zero_extent_is_included_and_aligned(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "image.raw"
            size = MODULE.EBS_BLOCK_SIZE * 6
            with path.open("wb") as image:
                image.truncate(size)
            descriptor = os.open(path, os.O_RDWR)
            try:
                os.pwrite(descriptor, b"\0" * 4096, MODULE.EBS_BLOCK_SIZE * 2 + 4096)
                ranges = MODULE.allocated_ranges(descriptor, size)
            finally:
                os.close(descriptor)

            self.assertIn(2, MODULE.block_indices(ranges))

    def test_adjacent_aligned_ranges_have_unique_ordered_blocks(self):
        ranges = [
            (0, MODULE.EBS_BLOCK_SIZE * 2),
            (MODULE.EBS_BLOCK_SIZE * 2, MODULE.EBS_BLOCK_SIZE * 4),
        ]

        self.assertEqual([0, 1, 2, 3], MODULE.block_indices(ranges))

    def test_rejects_duplicate_ranges(self):
        ranges = [
            (0, MODULE.EBS_BLOCK_SIZE * 2),
            (MODULE.EBS_BLOCK_SIZE, MODULE.EBS_BLOCK_SIZE * 3),
        ]

        with self.assertRaises(SystemExit):
            MODULE.block_indices(ranges)


if __name__ == "__main__":
    unittest.main()
