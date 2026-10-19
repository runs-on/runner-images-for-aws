package main

import (
	"encoding/binary"
	"errors"
	"reflect"
	"testing"
)

func TestFileItem(t *testing.T) {
	for _, tc := range []struct {
		name string
		ext  []extent
		want item
	}{
		{"ordinary", []extent{{16, 100}}, item{"file", 16, 1}},
		{"sparse CompactOS stub", []extent{{256, -1}}, item{"file:WofCompressedData", 4, 1}},
		{"empty CompactOS stub", nil, item{"file:WofCompressedData", 4, 1}},
		{"partially sparse", []extent{{8, -1}, {16, 100}}, item{"file", 16, 1}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			// Feed the documented NTFS buffer format through the real decoder.
			raw := make([]byte, 16+16*len(tc.ext))
			binary.LittleEndian.PutUint32(raw, uint32(len(tc.ext)))
			for i, e := range tc.ext {
				binary.LittleEndian.PutUint64(raw[16+i*16:], uint64(e.nextVcn))
				binary.LittleEndian.PutUint64(raw[24+i*16:], uint64(e.lcn))
			}
			got, err := fileItem("file", func(path string) ([]extent, int64, error) {
				if path == "file:WofCompressedData" {
					return []extent{{4, 200}}, 4, nil
				}
				return decodeExtents(raw)
			})
			if err != nil || got != tc.want {
				t.Fatalf("got %+v, %v; want %+v", got, err, tc.want)
			}
		})
	}
}

func TestPackFiles(t *testing.T) {
	collision := errors.New("destination occupied")
	for _, tc := range []struct {
		name       string
		failAt     int64
		refreshed  [][2]int64
		persistent bool
		want       map[string]int64
		wantErr    bool
	}{
		{"initial layout", -1, nil, false, map[string]int64{"a": 128, "b": 144, "c": 160}, false},
		{"collision before first move", 128, [][2]int64{{256, 512}}, false, map[string]int64{"a": 256, "b": 272, "c": 288}, false},
		{"collision after one move", 144, [][2]int64{{256, 512}}, false, map[string]int64{"a": 128, "b": 256, "c": 272}, false},
		{"space exhausted after refresh", 128, nil, false, map[string]int64{}, true},
		{"persistent failure", 128, [][2]int64{{128, 512}}, true, map[string]int64{}, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			positions := map[string]int64{}
			attempts := 0
			files := []item{{"a", 16, 1}, {"b", 16, 1}, {"c", 16, 1}}
			moved, clusters, err := packFiles(files, [][2]int64{{128, 512}}, func() [][2]int64 {
				return append([][2]int64(nil), tc.refreshed...)
			}, func(it item, target int64) error {
				attempts++
				if tc.persistent || target == tc.failAt {
					return collision
				}
				positions[it.path] = target
				return nil
			})
			if (err != nil) != tc.wantErr {
				t.Fatalf("error = %v, wantErr = %v", err, tc.wantErr)
			}
			if !reflect.DeepEqual(positions, tc.want) {
				t.Fatalf("positions = %v, want %v", positions, tc.want)
			}
			if moved != len(positions) || clusters != int64(moved)*16 {
				t.Fatalf("wrong totals: moved=%d clusters=%d", moved, clusters)
			}
			if tc.persistent && attempts != 3 {
				t.Fatalf("retry budget: %d attempts, want 3", attempts)
			}
		})
	}
}

func TestPackFilesRequiresAllocatedFiles(t *testing.T) {
	if _, _, err := packFiles(nil, nil, nil, nil); err == nil {
		t.Fatal("empty boot set succeeded")
	}
}
