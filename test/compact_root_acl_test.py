import importlib.util
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).parent.parent / "patches/ubuntu/files/compact-root-acl.py"
SPEC = importlib.util.spec_from_file_location("compact_root_acl", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class CompactRootAclTest(unittest.TestCase):
    def test_capture_batches_paths_and_includes_root_without_following_symlinks(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            for index in range(MODULE.BATCH_PATH_LIMIT + 5):
                (root / f"dir-{index:04d}").mkdir()
            (root / "outside-link").symlink_to("/does-not-exist")
            calls = []

            def fake_run(command, **kwargs):
                calls.append(command)
                paths = command[command.index("--") + 1 :]
                output = ""
                if str(root) in paths:
                    output = f"# file: {root}\n# owner: 0\n# group: 0\nuser::rwx\nuser:123:r-x\ngroup::r-x\nmask::r-x\nother::---\n\n"
                return subprocess.CompletedProcess(command, 0, stdout=output)

            with mock.patch.object(MODULE.subprocess, "run", side_effect=fake_run):
                manifest = MODULE.capture(root, ())

            self.assertGreater(len(calls), 1)
            self.assertLess(len(calls), MODULE.BATCH_PATH_LIMIT)
            self.assertTrue(all("--physical" in command for command in calls))
            self.assertTrue(any(str(root) in command for command in calls))
            self.assertEqual(["."], [entry["path"] for entry in manifest["entries"]])

    def test_rejects_acl_on_non_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            file_path = root / "file"
            file_path.write_text("data", encoding="utf-8")
            output = f"# file: {file_path}\nuser::rw-\nuser:123:r--\ngroup::r--\nmask::r--\nother::---\n\n"
            completed = subprocess.CompletedProcess([], 0, stdout=output)
            with mock.patch.object(MODULE.subprocess, "run", return_value=completed):
                with self.assertRaises(SystemExit):
                    MODULE.capture(root, ())

    def test_getfacl_path_round_trip(self):
        path = "/tmp/back\\slash\nand-newline"
        self.assertEqual(path, MODULE.decode_getfacl_path(MODULE.encode_getfacl_path(path)))


if __name__ == "__main__":
    unittest.main()
