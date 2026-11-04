package main

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

func TestPrefetchRunnerFilesReadsBinAndNewestNode(t *testing.T) {
	t.Parallel()

	home := t.TempDir()
	files := map[string]int{
		"bin/Runner.Listener.dll":      1000,
		"bin/sub/Runner.Worker.dll":    2*runnerPrefetchChunk + 7, // read in three pieces
		"bin/empty":                    0,
		"externals/node24/bin/node":    runnerPrefetchChunk + 1,
		"externals/node20/bin/node":    5000, // older Node: not read
		"externals/git/bin/git":        5000, // not the runner's: not read
		"_work/a-previous-job/bigfile": 5000,
	}
	for name, size := range files {
		path := filepath.Join(home, name)
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, make([]byte, size), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Symlink("Runner.Listener.dll", filepath.Join(home, "bin", "link")); err != nil {
		t.Fatal(err)
	}

	read, err := prefetchRunnerFiles(context.Background(), home)
	if err != nil {
		t.Fatalf("prefetchRunnerFiles: %v", err)
	}
	if want := int64(1000 + 2*runnerPrefetchChunk + 7 + runnerPrefetchChunk + 1); read != want {
		t.Fatalf("read %d bytes, want %d", read, want)
	}
}

func TestPrefetchRunnerFilesWithoutRunner(t *testing.T) {
	t.Parallel()

	read, err := prefetchRunnerFiles(context.Background(), t.TempDir())
	if err != nil || read != 0 {
		t.Fatalf("got %d bytes, %v; want nothing read and no error", read, err)
	}
}

func TestPrefetchRunnerFilesStopsAtDeadline(t *testing.T) {
	t.Parallel()

	home := t.TempDir()
	if err := os.MkdirAll(filepath.Join(home, "bin"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(home, "bin", "f"), make([]byte, 10), 0o644); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := prefetchRunnerFiles(ctx, home); err == nil {
		t.Fatal("expected the cancelled context's error")
	}
}

func TestNewestNode(t *testing.T) {
	t.Parallel()

	for _, tc := range []struct {
		dirs []string
		want string
	}{
		{[]string{"node20", "node24", "node9", "git"}, "node24"},
		{[]string{"node20"}, "node20"},
		{[]string{"git", "nodejs"}, ""},
		{nil, ""},
	} {
		externals := t.TempDir()
		for _, d := range tc.dirs {
			if err := os.Mkdir(filepath.Join(externals, d), 0o755); err != nil {
				t.Fatal(err)
			}
		}
		got := newestNode(externals)
		if tc.want == "" && got != "" || tc.want != "" && got != filepath.Join(externals, tc.want) {
			t.Errorf("newestNode(%v) = %q, want %q", tc.dirs, got, tc.want)
		}
	}
}
