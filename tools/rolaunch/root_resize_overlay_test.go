package main

import (
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
)

func TestResolveRootResizeMountUsesOverlayBacking(t *testing.T) {
	marker := filepath.Join(t.TempDir(), "backing-root-mount")
	if err := os.WriteFile(marker, []byte("/.bootstrap\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	mount, err := resolveRootResizeMount(marker,
		func() (string, string, error) { return "overlay", "overlay", nil },
		func(path string) (string, string, error) {
			if path != "/.bootstrap" {
				t.Fatalf("unexpected backing path %q", path)
			}
			return "/dev/nvme0n1p1", "ext4", nil
		})
	if err != nil {
		t.Fatal(err)
	}
	if mount.path != "/.bootstrap" || mount.source != "/dev/nvme0n1p1" || mount.fsType != "ext4" {
		t.Fatalf("unexpected mount: %#v", mount)
	}
}

func TestResolveRootResizeMountRejectsUnsafeMarker(t *testing.T) {
	marker := filepath.Join(t.TempDir(), "backing-root-mount")
	if err := os.WriteFile(marker, []byte("/.bootstrap/../etc\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	_, err := resolveRootResizeMount(marker,
		func() (string, string, error) { return "", "", nil },
		func(string) (string, string, error) { return "", "", nil })
	if err == nil || !strings.Contains(err.Error(), "backing root mount marker") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestFilesystemSizeAtUsesBackingPath(t *testing.T) {
	usedPath := ""
	size, err := filesystemSizeAt("/.bootstrap", func(path string, value *syscall.Statfs_t) error {
		usedPath = path
		value.Blocks = 10
		value.Bsize = 4096
		return nil
	})
	if err != nil || usedPath != "/.bootstrap" || size != 40960 {
		t.Fatalf("path=%q size=%d err=%v", usedPath, size, err)
	}
}

func TestMountedPathInfoResolvesDevRootFromMountDeviceNumber(t *testing.T) {
	sysfsRoot := t.TempDir()
	devicePath := filepath.Join(sysfsRoot, "devices", "pci0000:00", "nvme", "nvme0", "nvme0n1", "nvme0n1p1")
	if err := os.MkdirAll(filepath.Dir(devicePath), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(devicePath, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	deviceLink := filepath.Join(sysfsRoot, "dev", "block", "259:1")
	if err := os.MkdirAll(filepath.Dir(deviceLink), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(devicePath, deviceLink); err != nil {
		t.Fatal(err)
	}

	rawMountInfo := []byte("29 23 259:1 / /.bootstrap rw,relatime - ext4 /dev/root rw\n")
	source, fsType, err := mountedPathInfoFrom(rawMountInfo, "/.bootstrap", sysfsRoot)
	if err != nil {
		t.Fatal(err)
	}
	if source != "/dev/nvme0n1p1" || fsType != "ext4" {
		t.Fatalf("source=%q fsType=%q", source, fsType)
	}
}

func TestMountedPathInfoRejectsUnresolvedDevRoot(t *testing.T) {
	rawMountInfo := []byte("29 23 259:1 / /.bootstrap rw,relatime - ext4 /dev/root rw\n")
	_, _, err := mountedPathInfoFrom(rawMountInfo, "/.bootstrap", t.TempDir())
	if err == nil || !strings.Contains(err.Error(), "resolve mount /.bootstrap source /dev/root through device 259:1") {
		t.Fatalf("unexpected error: %v", err)
	}
}
