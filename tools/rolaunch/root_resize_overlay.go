package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"unicode"
	"unicode/utf8"
)

const defaultBackingRootMarker = "/etc/runs-on-overlay/backing-root-mount"

type rootResizeMount struct {
	path   string
	source string
	fsType string
}

func resolveRootResizeMount(
	markerPath string,
	normalRootInfo func() (string, string, error),
	backingMountInfo func(string) (string, string, error),
) (rootResizeMount, error) {
	rawMarker, err := os.ReadFile(markerPath)
	if err != nil {
		if !os.IsNotExist(err) {
			return rootResizeMount{}, fmt.Errorf("read backing root mount marker %s: %w", markerPath, err)
		}

		source, fsType, err := normalRootInfo()
		if err != nil {
			return rootResizeMount{}, err
		}
		return rootResizeMount{path: "/", source: source, fsType: fsType}, nil
	}

	backingPath, err := parseBackingRootMountMarker(rawMarker)
	if err != nil {
		return rootResizeMount{}, fmt.Errorf("invalid backing root mount marker %s: %w", markerPath, err)
	}
	source, fsType, err := backingMountInfo(backingPath)
	if err != nil {
		return rootResizeMount{}, fmt.Errorf("resolve backing root mount %s: %w", backingPath, err)
	}
	if source == "" || fsType == "" {
		return rootResizeMount{}, fmt.Errorf("resolve backing root mount %s: empty source or filesystem type", backingPath)
	}

	return rootResizeMount{path: backingPath, source: source, fsType: fsType}, nil
}

func parseBackingRootMountMarker(raw []byte) (string, error) {
	if len(raw) > 4096 {
		return "", fmt.Errorf("value is too large")
	}
	value := strings.TrimSuffix(strings.TrimSuffix(string(raw), "\n"), "\r")
	if value == "" {
		return "", fmt.Errorf("value is empty")
	}
	if !utf8.ValidString(value) {
		return "", fmt.Errorf("value is not valid UTF-8")
	}
	if strings.IndexFunc(value, unicode.IsControl) >= 0 {
		return "", fmt.Errorf("value contains a control character")
	}
	if strings.TrimSpace(value) != value {
		return "", fmt.Errorf("value has leading or trailing whitespace")
	}
	if !filepath.IsAbs(value) || filepath.Clean(value) != value {
		return "", fmt.Errorf("path %q is not a canonical absolute path", value)
	}
	if value == "/" {
		return "", fmt.Errorf("path must name the backing mount, not the overlay root")
	}
	return value, nil
}

func mountedPathInfo(mountPath string) (string, string, error) {
	info, err := os.Stat(mountPath)
	if err != nil {
		return "", "", fmt.Errorf("stat mount path: %w", err)
	}
	if !info.IsDir() {
		return "", "", fmt.Errorf("mount path is not a directory")
	}
	raw, err := os.ReadFile("/proc/self/mountinfo")
	if err != nil {
		return "", "", fmt.Errorf("read /proc/self/mountinfo: %w", err)
	}
	return mountInfoForExactPath(raw, mountPath)
}

func mountInfoForExactPath(raw []byte, mountPath string) (string, string, error) {
	for _, line := range strings.Split(string(raw), "\n") {
		fields := strings.Fields(line)
		separator := -1
		for index, field := range fields {
			if field == "-" {
				separator = index
				break
			}
		}
		if separator < 6 || separator+2 >= len(fields) || unescapeProcMountField(fields[4]) != mountPath {
			continue
		}
		source := unescapeProcMountField(fields[separator+2])
		fsType := fields[separator+1]
		if source == "" || fsType == "" {
			return "", "", fmt.Errorf("mount %s has an empty source or filesystem type", mountPath)
		}
		return source, fsType, nil
	}
	return "", "", fmt.Errorf("%s is not an active mount point", mountPath)
}

func unescapeProcMountField(value string) string {
	return strings.NewReplacer(
		`\040`, " ",
		`\011`, "\t",
		`\012`, "\n",
		`\134`, `\`,
	).Replace(value)
}

func filesystemSizeAt(path string, statfs func(string, *syscall.Statfs_t) error) (int64, error) {
	var filesystem syscall.Statfs_t
	if err := statfs(path, &filesystem); err != nil {
		return 0, fmt.Errorf("statfs %s: %w", path, err)
	}
	return int64(filesystem.Blocks) * int64(filesystem.Bsize), nil
}
