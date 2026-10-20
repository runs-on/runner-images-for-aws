// bootpack moves the files a boot reads into contiguous free regions of the
// volume, in the order the boot reads them. A fresh EBS volume fetches
// snapshot data on first access and serves few of those fetches at once, so
// a cold Windows boot is bound by how scattered its reads are. Packing the
// boot set makes them sequential.
//
// It uses the NTFS defragmentation controls (FSCTL_GET_VOLUME_BITMAP,
// FSCTL_GET_RETRIEVAL_POINTERS, FSCTL_MOVE_FILE), which work on open files.
// CompactOS keeps a compressed file's data in its WofCompressedData stream and
// leaves the main stream sparse; that stream is what gets moved then.
package main

import (
	"bufio"
	"encoding/binary"
	"flag"
	"fmt"
	"os"
	"sort"
	"strings"

	"golang.org/x/sys/windows"
)

const (
	fsctlGetNtfsVolumeData    = 0x00090064
	fsctlGetVolumeBitmap      = 0x0009006F
	fsctlGetRetrievalPointers = 0x00090073
	fsctlMoveFile             = 0x00090074
	chunkBytes                = 512 * 1024
)

func main() {
	list := flag.String("list", `C:\ProgramData\RunsOn\bootlayout.txt`, "file list in boot order")
	volume := flag.String("volume", "C:", "volume")
	dryRun := flag.Bool("dry-run", false, "only report")
	minFree := flag.Int64("min-free-mib", 256, "smallest free run considered")
	extra := flag.String("extra", "", "comma-separated paths packed first (registry hives)")
	flag.Parse()

	vol, err := windows.CreateFile(windows.StringToUTF16Ptr(`\\.\`+*volume), windows.GENERIC_READ|windows.GENERIC_WRITE, windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE, nil, windows.OPEN_EXISTING, 0, 0)
	if err != nil {
		fatal("open volume: %v", err)
	}
	defer windows.CloseHandle(vol)

	clusterSize := ntfsClusterSize(vol)
	totalClusters, bitmap := volumeBitmap(vol)
	fmt.Printf("cluster size %d, %d clusters, %d free\n", clusterSize, totalClusters, countFree(bitmap, totalClusters))

	files := readList(*list)
	if *extra != "" {
		files = append(strings.Split(*extra, ","), files...)
	}
	var items []item
	var needed int64
	for _, p := range files {
		it, err := fileItem(p, retrievalPointers)
		if err != nil || it.clusters == 0 {
			continue
		}
		items = append(items, it)
		needed += it.clusters
	}
	fragmented := 0
	for _, it := range items {
		if it.extents > 1 {
			fragmented++
		}
	}
	fmt.Printf("%d files, %d clusters (%d MiB), %d fragmented\n", len(items), needed, needed*clusterSize>>20, fragmented)
	fmt.Printf("512 KiB chunks touched by the set now: %d\n", chunkCount(items, clusterSize))

	runs := freeRuns(bitmap, totalClusters, *minFree<<20/clusterSize)
	sort.Slice(runs, func(i, j int) bool { return runs[i][1]-runs[i][0] > runs[j][1]-runs[j][0] })
	if len(runs) == 0 {
		fatal("no free run of at least %d MiB", *minFree)
	}
	fmt.Printf("largest free runs (clusters): ")
	for i, r := range runs {
		if i == 5 {
			break
		}
		fmt.Printf("[%d +%d] ", r[0], r[1]-r[0])
	}
	fmt.Println()
	if *dryRun {
		return
	}

	refresh := func() [][2]int64 {
		total, current := volumeBitmap(vol)
		fresh := freeRuns(current, total, *minFree<<20/clusterSize)
		sort.Slice(fresh, func(i, j int) bool { return fresh[i][1]-fresh[i][0] > fresh[j][1]-fresh[j][0] })
		return fresh
	}
	moved, movedClusters, err := packFiles(items, runs, refresh, func(it item, lcn int64) error {
		return moveWhole(vol, it.path, lcn, it.clusters)
	})
	if err != nil {
		fatal("packing stopped after %d files: %v", moved, err)
	}
	fmt.Printf("moved %d files (%d MiB)\n", moved, movedClusters*clusterSize>>20)
	fmt.Printf("512 KiB chunks touched by the set after packing: %d\n", chunkCount(items, clusterSize))
}

func fatal(format string, a ...any) {
	fmt.Fprintf(os.Stderr, format+"\n", a...)
	os.Exit(1)
}

func readList(path string) []string {
	f, err := os.Open(path)
	if err != nil {
		fatal("open list: %v", err)
	}
	defer f.Close()
	var out []string
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 64*1024), 1024*1024)
	for sc.Scan() {
		p := strings.TrimSpace(sc.Text())
		if p == "" || strings.HasPrefix(p, "#") {
			continue
		}
		out = append(out, p)
	}
	return out
}

func ioctl(h windows.Handle, code uint32, in []byte, out []byte) (uint32, error) {
	var n uint32
	var inPtr, outPtr *byte
	if len(in) > 0 {
		inPtr = &in[0]
	}
	if len(out) > 0 {
		outPtr = &out[0]
	}
	err := windows.DeviceIoControl(h, code, inPtr, uint32(len(in)), outPtr, uint32(len(out)), &n, nil)
	return n, err
}

func ntfsClusterSize(vol windows.Handle) int64 {
	out := make([]byte, 128)
	if _, err := ioctl(vol, fsctlGetNtfsVolumeData, nil, out); err != nil {
		fatal("ntfs volume data: %v", err)
	}
	// NTFS_VOLUME_DATA_BUFFER: VolumeSerialNumber(8) NumberSectors(8) TotalClusters(8)
	// FreeClusters(8) TotalReserved(8) BytesPerSector(4) BytesPerCluster(4) ...
	return int64(binary.LittleEndian.Uint32(out[44:48]))
}

func volumeBitmap(vol windows.Handle) (int64, []byte) {
	in := make([]byte, 8)
	out := make([]byte, 16+64<<20)
	n, err := ioctl(vol, fsctlGetVolumeBitmap, in, out)
	if err != nil && err != windows.ERROR_MORE_DATA {
		fatal("volume bitmap: %v", err)
	}
	total := int64(binary.LittleEndian.Uint64(out[8:16]))
	return total, out[16:n]
}

func openForMove(path string) (windows.Handle, error) {
	return windows.CreateFile(windows.StringToUTF16Ptr(path), windows.FILE_READ_ATTRIBUTES|windows.SYNCHRONIZE, windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE|windows.FILE_SHARE_DELETE, nil, windows.OPEN_EXISTING, windows.FILE_FLAG_BACKUP_SEMANTICS, 0)
}

func retrievalPointers(path string) ([]extent, int64, error) {
	h, err := openForMove(path)
	if err != nil {
		return nil, 0, err
	}
	defer windows.CloseHandle(h)
	in := make([]byte, 8)
	out := make([]byte, 16+16*4096)
	n, err := ioctl(h, fsctlGetRetrievalPointers, in, out)
	if err != nil {
		if err == windows.ERROR_HANDLE_EOF {
			return nil, 0, nil // resident or empty
		}
		return nil, 0, err
	}
	return decodeExtents(out[:n])
}

func moveWhole(vol windows.Handle, path string, lcn int64, clusters int64) error {
	h, err := openForMove(path)
	if err != nil {
		return err
	}
	defer windows.CloseHandle(h)
	// MOVE_FILE_DATA: HANDLE FileHandle; LARGE_INTEGER StartingVcn; LARGE_INTEGER StartingLcn; DWORD ClusterCount;
	in := make([]byte, 32)
	binary.LittleEndian.PutUint64(in[0:8], uint64(h))
	binary.LittleEndian.PutUint64(in[8:16], 0)
	binary.LittleEndian.PutUint64(in[16:24], uint64(lcn))
	binary.LittleEndian.PutUint32(in[24:28], uint32(clusters))
	_, err = ioctl(vol, fsctlMoveFile, in, nil)
	return err
}

func chunkCount(items []item, clusterSize int64) int {
	chunks := map[int64]struct{}{}
	for _, it := range items {
		ext, _, err := retrievalPointers(it.path)
		if err != nil {
			continue
		}
		vcn := int64(0)
		for _, e := range ext {
			length := e.nextVcn - vcn
			vcn = e.nextVcn
			if e.lcn == -1 {
				continue
			}
			startByte := e.lcn * clusterSize
			endByte := (e.lcn + length) * clusterSize
			for c := startByte / chunkBytes; c < (endByte+chunkBytes-1)/chunkBytes; c++ {
				chunks[c] = struct{}{}
			}
		}
	}
	return len(chunks)
}
