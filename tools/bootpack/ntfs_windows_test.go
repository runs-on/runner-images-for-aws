package main

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"golang.org/x/sys/windows"
)

// Exercise real NTFS stream discovery and moves. Windows CI runs as an
// administrator; an access failure is a test failure, not a skipped check.
func TestNTFSPacking(t *testing.T) {
	dir := t.TempDir()
	data := bytes.Repeat([]byte("bootpack regression data\n"), 64*1024)
	for _, compressed := range []bool{false, true} {
		name := "ordinary.bin"
		if compressed {
			name = "compressed.bin"
		}
		path := filepath.Join(dir, name)
		if err := os.WriteFile(path, data, 0600); err != nil {
			t.Fatal(err)
		}
		if compressed {
			if out, err := exec.Command("compact.exe", "/C", "/EXE:LZX", path).CombinedOutput(); err != nil {
				t.Fatalf("compact: %v: %s", err, out)
			}
		}
		it, err := fileItem(path, retrievalPointers)
		if err != nil {
			t.Fatal(err)
		}
		if it.clusters == 0 || strings.HasSuffix(it.path, ":WofCompressedData") != compressed {
			t.Fatalf("wrong stream: %+v", it)
		}
		vol, err := windows.CreateFile(windows.StringToUTF16Ptr(`\\.\`+filepath.VolumeName(dir)), windows.GENERIC_READ|windows.GENERIC_WRITE, windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE, nil, windows.OPEN_EXISTING, 0, 0)
		if err != nil {
			t.Fatal(err)
		}
		refresh := func() [][2]int64 {
			total, bitmap := volumeBitmap(vol)
			return freeRuns(bitmap, total, it.clusters)
		}
		moved, _, moveErr := packFiles([]item{it}, refresh(), refresh, func(it item, lcn int64) error {
			return moveWhole(vol, it.path, lcn, it.clusters)
		})
		windows.CloseHandle(vol)
		if moveErr != nil || moved != 1 {
			t.Fatalf("pack: moved=%d error=%v", moved, moveErr)
		}
		got, err := os.ReadFile(path)
		if err != nil || !bytes.Equal(got, data) {
			t.Fatalf("file content changed: %v", err)
		}
	}
}
