package main

import (
	"encoding/binary"
	"fmt"
)

type extent struct {
	nextVcn int64
	lcn     int64
}

type item struct {
	path     string
	clusters int64
	extents  int
}

// Keep holes in the extent list so subsequent VCN lengths remain accurate.
func decodeExtents(out []byte) ([]extent, int64, error) {
	if len(out) < 16 {
		return nil, 0, fmt.Errorf("truncated retrieval pointers header")
	}
	count := int(binary.LittleEndian.Uint32(out[:4]))
	if count > (len(out)-16)/16 {
		return nil, 0, fmt.Errorf("truncated retrieval pointers extents")
	}
	start := int64(binary.LittleEndian.Uint64(out[8:16]))
	last := start
	ext := make([]extent, 0, count)
	for i := 0; i < count; i++ {
		next := int64(binary.LittleEndian.Uint64(out[16+i*16 : 24+i*16]))
		lcn := int64(binary.LittleEndian.Uint64(out[24+i*16 : 32+i*16]))
		if next <= last {
			return nil, 0, fmt.Errorf("invalid retrieval pointer VCN")
		}
		ext = append(ext, extent{next, lcn})
		last = next
	}
	return ext, last - start, nil
}

func allocatedExtents(ext []extent) int {
	count := 0
	for _, e := range ext {
		if e.lcn != -1 {
			count++
		}
	}
	return count
}

func fileItem(path string, retrieve func(string) ([]extent, int64, error)) (item, error) {
	ext, clusters, err := retrieve(path)
	if err != nil {
		return item{}, err
	}
	if allocatedExtents(ext) == 0 {
		path += ":WofCompressedData"
		ext, clusters, err = retrieve(path)
		if err != nil {
			return item{}, err
		}
	}
	count := allocatedExtents(ext)
	if count == 0 {
		return item{}, nil
	}
	return item{path, clusters, count}, nil
}

// The bitmap is only a snapshot. Refresh it after a failed move and retry
// the same file, with a bound for persistent errors or a very busy volume.
// Failed packing must not be published as a successful optimization.
func packFiles(items []item, runs [][2]int64, refresh func() [][2]int64, move func(item, int64) error) (int, int64, error) {
	moved := 0
	var clusters int64
	if len(items) == 0 {
		return 0, 0, fmt.Errorf("no allocated boot files")
	}
	for _, it := range items {
		for attempt := 0; ; attempt++ {
			for len(runs) > 0 && runs[0][1]-runs[0][0] < it.clusters {
				runs = runs[1:]
			}
			if len(runs) == 0 {
				return moved, clusters, fmt.Errorf("no free run fits %s", it.path)
			}
			if err := move(it, runs[0][0]); err != nil {
				if attempt == 2 {
					return moved, clusters, fmt.Errorf("move %s after 3 attempts: %w", it.path, err)
				}
				runs = refresh()
				continue
			}
			moved++
			clusters += it.clusters
			runs[0][0] += it.clusters
			break
		}
	}
	return moved, clusters, nil
}

func isFree(bitmap []byte, c int64) bool {
	return c/8 < int64(len(bitmap)) && bitmap[c/8]&(1<<(uint(c)%8)) == 0
}

func countFree(bitmap []byte, total int64) int64 {
	var free int64
	for c := int64(0); c < total; c++ {
		if isFree(bitmap, c) {
			free++
		}
	}
	return free
}

func freeRuns(bitmap []byte, total int64, minClusters int64) [][2]int64 {
	var runs [][2]int64
	start := int64(-1)
	for c := int64(0); c <= total; c++ {
		free := c < total && isFree(bitmap, c)
		if free && start < 0 {
			start = c
		}
		if !free && start >= 0 {
			if c-start >= minClusters {
				runs = append(runs, [2]int64{start, c})
			}
			start = -1
		}
	}
	return runs
}
