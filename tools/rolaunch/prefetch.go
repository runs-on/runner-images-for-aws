package main

import (
	"context"
	"errors"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
)

const (
	// Reads in flight. A fresh EBS volume fetches each block from its
	// snapshot on first read, one slow request at a time per reader: many
	// readers hide that latency.
	runnerPrefetchWorkers = 32
	// Big files (node is ~100 MB) are read in pieces by several workers.
	runnerPrefetchChunk = 4 << 20
)

// prefetchRunnerFiles reads the GitHub runner's own files and its newest
// Node once, in parallel, so that the runner's first start and its first
// JavaScript action find them in the page cache. Measured on fresh Ubuntu 26
// volumes, started 1.5 s before them, it took the runner's first start plus
// its first node run from 2.3 to 0.9 s (x64) and 1.95 to 1.2 s (arm64). It
// returns the bytes read; a missing runner reads nothing.
func prefetchRunnerFiles(ctx context.Context, home string) (int64, error) {
	roots := []string{filepath.Join(home, "bin")}
	if node := newestNode(filepath.Join(home, "externals")); node != "" {
		roots = append(roots, node)
	}

	type chunk struct {
		path   string
		offset int64
		size   int64
	}
	var chunks []chunk
	for _, root := range roots {
		err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
			if err != nil {
				if path == root && errors.Is(err, fs.ErrNotExist) {
					return fs.SkipDir
				}
				return err
			}
			if !d.Type().IsRegular() {
				return nil
			}
			info, err := d.Info()
			if err != nil {
				return err
			}
			for offset := int64(0); offset < info.Size(); offset += runnerPrefetchChunk {
				chunks = append(chunks, chunk{path, offset, min(runnerPrefetchChunk, info.Size()-offset)})
			}
			return nil
		})
		if err != nil {
			return 0, err
		}
	}

	var (
		read     atomic.Int64
		next     atomic.Int64
		wg       sync.WaitGroup
		errOnce  sync.Once
		firstErr error
	)
	for range min(runnerPrefetchWorkers, len(chunks)) {
		wg.Add(1)
		go func() {
			defer wg.Done()
			buf := make([]byte, runnerPrefetchChunk)
			for ctx.Err() == nil {
				i := next.Add(1) - 1
				if i >= int64(len(chunks)) {
					return
				}
				c := chunks[i]
				n, err := readAt(c.path, buf[:c.size], c.offset)
				read.Add(int64(n))
				if err != nil {
					errOnce.Do(func() { firstErr = err })
					return
				}
			}
		}()
	}
	wg.Wait()
	if firstErr == nil {
		firstErr = ctx.Err()
	}
	return read.Load(), firstErr
}

func readAt(path string, buf []byte, offset int64) (int, error) {
	f, err := os.Open(path)
	if err != nil {
		return 0, err
	}
	defer f.Close()
	n, err := f.ReadAt(buf, offset)
	if errors.Is(err, io.EOF) {
		// The file shrank since it was listed: what was read still counts.
		err = nil
	}
	return n, err
}

// newestNode is the runner's newest Node (externals/node24 over node20),
// which the runner forces older actions onto; "" when there is none.
func newestNode(externals string) string {
	entries, err := os.ReadDir(externals)
	if err != nil {
		return ""
	}
	var versions []int
	for _, e := range entries {
		v, err := strconv.Atoi(strings.TrimPrefix(e.Name(), "node"))
		if e.IsDir() && strings.HasPrefix(e.Name(), "node") && err == nil {
			versions = append(versions, v)
		}
	}
	if len(versions) == 0 {
		return ""
	}
	sort.Ints(versions)
	return filepath.Join(externals, "node"+strconv.Itoa(versions[len(versions)-1]))
}
