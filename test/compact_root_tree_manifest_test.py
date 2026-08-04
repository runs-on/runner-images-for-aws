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
    / "compact-root-tree-manifest.py"
)
SPEC = importlib.util.spec_from_file_location("compact_tree_manifest", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class CompactRootTreeManifestTest(unittest.TestCase):
    def test_records_content_xattrs_symlinks_and_hardlinks(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            payload = root / "payload"
            payload.write_text("content", encoding="utf-8")
            hardlink = root / "hardlink"
            os.link(payload, hardlink)
            (root / "symlink").symlink_to("payload")
            xattrs_supported = hasattr(os, "setxattr")
            if xattrs_supported:
                try:
                    os.setxattr(payload, "user.runs-on-test", b"value")
                except OSError as error:
                    self.skipTest(f"filesystem has no user xattr support: {error}")

            manifest = MODULE.build_manifest(root, ())
            entries = {entry["path"]: entry for entry in manifest["entries"]}

            self.assertEqual(4, manifest["entry_count"])
            self.assertEqual(1, manifest["hardlink_group_count"])
            self.assertEqual("content", payload.read_text(encoding="utf-8"))
            self.assertEqual(entries["payload"]["sha256"], entries["hardlink"]["sha256"])
            self.assertEqual(["hardlink", "payload"], entries["payload"]["hardlinks"])
            if xattrs_supported:
                self.assertIn("user.runs-on-test", entries["payload"]["xattrs"])
            self.assertEqual("payload", entries["symlink"]["target"])

    def test_excludes_complete_subtrees(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            excluded = root / "dynamic"
            excluded.mkdir()
            (excluded / "value").write_text("dynamic", encoding="utf-8")
            (root / "kept").write_text("kept", encoding="utf-8")

            manifest = MODULE.build_manifest(root, ("dynamic",))

            self.assertEqual([".", "kept"], [entry["path"] for entry in manifest["entries"]])


if __name__ == "__main__":
    unittest.main()
