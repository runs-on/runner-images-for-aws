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

type extent struct {
	nextVcn int64
	lcn     int64
}

type item struct {
	path     string
	clusters int64
	extents  int
}

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
		stream := p
		ext, size, err := retrievalPointers(stream)
		if err == nil && size == 0 {
			stream = p + ":WofCompressedData"
			ext, size, err = retrievalPointers(stream)
		}
		if err != nil || size == 0 {
			continue
		}
		items = append(items, item{stream, size, len(ext)})
		needed += size
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

	// Fill free runs from the largest, each file whole; a file that does not
	// fit the rest of the current run goes to the next one.
	runIdx := 0
	cursor, end := runs[0][0], runs[0][1]
	var moved, failed, movedClusters int64
	for _, it := range items {
		for cursor+it.clusters > end {
			runIdx++
			if runIdx >= len(runs) {
				fatal("ran out of free runs after %d files", moved)
			}
			cursor, end = runs[runIdx][0], runs[runIdx][1]
		}
		if err := moveWhole(vol, it.path, cursor, it.clusters); err != nil {
			failed++
			if failed <= 20 {
				fmt.Printf("skip %s: %v\n", it.path, err)
			}
			continue
		}
		moved++
		movedClusters += it.clusters
		cursor += it.clusters
	}
	fmt.Printf("moved %d files (%d MiB), %d failed\n", moved, movedClusters*clusterSize>>20, failed)
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
	count := int64(binary.LittleEndian.Uint32(out[0:4]))
	startVcn := int64(binary.LittleEndian.Uint64(out[8:16]))
	var ext []extent
	last := startVcn
	for i := int64(0); i < count && 16+i*16+16 <= int64(n); i++ {
		next := int64(binary.LittleEndian.Uint64(out[16+i*16 : 24+i*16]))
		lcn := int64(binary.LittleEndian.Uint64(out[24+i*16 : 32+i*16]))
		if lcn != -1 { // sparse hole
			ext = append(ext, extent{next, lcn})
		}
		last = next
	}
	return ext, last - startVcn, nil
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
			startByte := e.lcn * clusterSize
			endByte := (e.lcn + length) * clusterSize
			for c := startByte / chunkBytes; c < (endByte+chunkBytes-1)/chunkBytes; c++ {
				chunks[c] = struct{}{}
			}
			vcn = e.nextVcn
		}
	}
	return len(chunks)
}
