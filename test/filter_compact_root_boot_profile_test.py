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
    / "filter-compact-root-boot-profile.py"
)
SPEC = importlib.util.spec_from_file_location("filter_compact_profile", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class FilterCompactRootBootProfileTest(unittest.TestCase):
    def test_resolves_symlinks_kernel_paths_and_hardlinks(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            library = root / "usr/lib/current"
            library.mkdir(parents=True)
            payload = library / "payload"
            payload.write_text("payload", encoding="utf-8")
            os.link(payload, library / "payload-hardlink")
            binary = root / "usr/bin"
            binary.mkdir(parents=True)
            (binary / "tool").symlink_to("../lib/current/payload")
            module = root / "usr/lib/modules/new-aws/kernel/module.ko.zst"
            module.parent.mkdir(parents=True)
            module.write_text("module", encoding="utf-8")
            modprobe = root / "usr/lib/modprobe.d/blacklist_linux-aws_new-aws.conf"
            modprobe.parent.mkdir(parents=True)
            modprobe.write_text("blacklist", encoding="utf-8")

            entries = [
                ("usr/bin/tool", 100),
                ("usr/lib/current/payload-hardlink", 99),
                ("usr/lib/modules/old-aws/kernel/module.ko.zst", 98),
                ("usr/lib/modprobe.d/blacklist_linux-aws_7.0.0-1009-aws.conf", 97),
                ("missing", 96),
                ("usr/lib/current", 95),
            ]
            filtered, report = MODULE.filter_profile(root, entries, "new-aws")

            self.assertEqual(
                [
                    ("usr/lib/current/payload", 100),
                    ("usr/lib/modules/new-aws/kernel/module.ko.zst", 98),
                    ("usr/lib/modprobe.d/blacklist_linux-aws_new-aws.conf", 97),
                ],
                filtered,
            )
            self.assertEqual(1, report["duplicate_inode_count"])
            self.assertEqual(1, report["missing_count"])
            self.assertEqual(1, report["non_regular_count"])

    def test_absolute_symlink_stays_inside_supplied_root(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / "usr/lib/target"
            target.parent.mkdir(parents=True)
            target.write_text("target", encoding="utf-8")
            link = root / "lib"
            link.symlink_to("/usr/lib")

            resolved, relative = MODULE.resolve_in_root(root, "lib/target")

            self.assertEqual(target, resolved)
            self.assertEqual("usr/lib/target", relative)


if __name__ == "__main__":
    unittest.main()
