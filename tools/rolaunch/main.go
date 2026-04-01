package main

import (
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const (
	defaultIMDSEndpoint       = "http://169.254.169.254"
	defaultWorkDir            = "/var/lib/rolaunch"
	defaultUserDataName       = "user-data.sh"
	defaultDoneMarkerName     = "runs-on-user-data.done"
	defaultUbuntuUser         = "ubuntu"
	defaultRootUser           = "root"
	defaultHostKeyPath        = "/etc/ssh/ssh_host_ed25519_key"
	defaultResolverConfigPath = "/etc/resolv.conf"
	defaultEC2Resolver        = "169.254.169.253"
	defaultAptSourcesListPath = "/etc/apt/sources.list"
	defaultAptSourcesDeb822   = "/etc/apt/sources.list.d/ubuntu.sources"
	defaultTimingsPath        = "/runs-on/timings.json"
	defaultRunnerListenerPath = "/home/runner/bin/Runner.Listener"
	defaultRunnerUser         = "runner"
	defaultReadinessTimeout   = 5 * time.Minute
	defaultReadinessInterval  = 250 * time.Millisecond
)

var ubuntuArchiveMirrorPattern = regexp.MustCompile(`https?://(?:(?:azure|[a-z0-9-]+\.ec2)\.)?archive\.ubuntu\.com/ubuntu/?`)

// NOTE: cloud-initramfs-growroot and cloud-guest-utils are still useful if root-volume resize
// support is required later, even if they are not part of this first iteration.
type config struct {
	imdsBase     string
	timeout      time.Duration
	workDir      string
	userDataPath string
	doneMarker   string
	timingsPath  string
}

type authorizedKeysTarget struct {
	userName string
	sshDir   string
	path     string
	uid      int
	gid      int
}

type instanceIdentity struct {
	InstanceID string `json:"instanceId"`
	Region     string `json:"region"`
}

type taskResult[T any] struct {
	value T
	err   error
}

type Step struct {
	Name string
	Time time.Time
}

type rootResizeResult struct {
	changed bool
	err     error
}

type timingRecorder struct {
	mu    sync.Mutex
	steps []Step
}

type asyncResult[T any] struct {
	ch <-chan taskResult[T]
}

type launcherOps struct {
	ensureHostKey               func() error
	warmupRunner                func(context.Context) (bool, error)
	makeWorkDir                 func(string) error
	ensureResolverConfig        func(string) error
	waitForInstanceIdentity     func(context.Context, config) (instanceIdentity, error)
	fetchUserData               func(context.Context, config) ([]byte, error)
	fetchTemporaryPublicKey     func(context.Context, config) ([]byte, error)
	prefetchMatchingBootstrap   func(context.Context, config, string, []byte) (bool, error)
	markerMatchesInstance       func(string, string) (bool, error)
	applyLocalAptMirror         func(string) error
	installAuthorizedKey        func([]byte) error
	prepareUserData             func(string, []byte) error
	executeUserData             func(context.Context, config) error
	markDone                    func(string, string) error
	startRootFilesystemResize   func(context.Context) <-chan rootResizeResult
	waitForRootFilesystemResize func(<-chan rootResizeResult) bool
}

func defaultLauncherOps() launcherOps {
	awsState := newAWSState()
	return launcherOps{
		ensureHostKey:        ensureHostKey,
		warmupRunner:         warmupRunnerListener,
		makeWorkDir:          func(path string) error { return os.MkdirAll(path, 0o700) },
		ensureResolverConfig: ensureResolverConfig,
		waitForInstanceIdentity: func(ctx context.Context, cfg config) (instanceIdentity, error) {
			return awsState.waitForReadinessAndFetchIdentity(ctx, cfg)
		},
		fetchUserData: func(ctx context.Context, cfg config) ([]byte, error) {
			return awsState.fetchUserData(ctx, cfg)
		},
		fetchTemporaryPublicKey: func(ctx context.Context, cfg config) ([]byte, error) {
			return awsState.fetchTemporaryPublicKey(ctx, cfg)
		},
		prefetchMatchingBootstrap: func(ctx context.Context, cfg config, region string, raw []byte) (bool, error) {
			return awsState.prefetchMatchingBootstrap(ctx, cfg, region, raw)
		},
		markerMatchesInstance:       markerMatchesInstance,
		applyLocalAptMirror:         applyLocalAptMirror,
		installAuthorizedKey:        installAuthorizedKey,
		prepareUserData:             prepareUserData,
		executeUserData:             executeUserDataScript,
		markDone:                    markDone,
		startRootFilesystemResize:   startRootFilesystemResize,
		waitForRootFilesystemResize: waitForRootFilesystemResize,
	}
}

func main() {
	var (
		imdsEndpoint = flag.String("imds", defaultIMDSEndpoint, "IMDS endpoint")
		timeout      = flag.Duration("timeout", defaultReadinessTimeout, "total startup timeout for waiting on network+IMDS")
		workDir      = flag.String("workdir", defaultWorkDir, "working directory for userdata artifacts")
	)
	flag.Parse()

	cfg := config{
		imdsBase:     *imdsEndpoint,
		timeout:      *timeout,
		workDir:      *workDir,
		userDataPath: filepath.Join(*workDir, defaultUserDataName),
		doneMarker:   filepath.Join(*workDir, defaultDoneMarkerName),
		timingsPath:  defaultTimingsPath,
	}

	ctx, cancel := context.WithTimeout(context.Background(), cfg.timeout)
	err := run(ctx, cfg)
	cancel()
	if err != nil {
		log.Fatalf("rolaunch failed: %v", err)
	}
}

func run(ctx context.Context, cfg config) error {
	return runWithOps(ctx, cfg, defaultLauncherOps())
}

func runWithOps(ctx context.Context, cfg config, ops launcherOps) error {
	recorder := newTimingRecorder()
	recorder.add("rolaunch.started")
	defer func() {
		if err := recorder.save(cfg.timingsPath); err != nil {
			log.Printf("warning: failed to save timing milestones to %s: %v", cfg.timingsPath, err)
		}
	}()

	rootResizeDone := ops.startRootFilesystemResize(ctx)

	hostKeyTask := startAsyncTask(func() error {
		if err := ops.ensureHostKey(); err != nil {
			return err
		}
		recorder.add("rolaunch.host-key-ready")
		return nil
	})
	warmupTask := startAsync(func() (bool, error) {
		return ops.warmupRunner(ctx)
	})
	defer func() {
		finishWarmupTask(warmupTask, recorder)
	}()
	workDirTask := startAsyncTask(func() error {
		if err := ops.makeWorkDir(cfg.workDir); err != nil {
			return fmt.Errorf("create workdir: %w", err)
		}
		return nil
	})
	resolverTask := startAsyncTask(func() error {
		return ops.ensureResolverConfig(defaultResolverConfigPath)
	})
	identityTask := startAsync(func() (instanceIdentity, error) {
		identity, err := ops.waitForInstanceIdentity(ctx, cfg)
		if err == nil {
			recorder.add("rolaunch.imds-ready")
			recorder.add("rolaunch.identity-ready")
		}
		return identity, err
	})

	identity, err := identityTask.wait()
	if err != nil {
		return fmt.Errorf("discover instance identity: %w", err)
	}

	alreadyProcessed, err := ops.markerMatchesInstance(cfg.doneMarker, identity.InstanceID)
	if err != nil {
		return err
	}
	if alreadyProcessed {
		if err := waitAllTasks(hostKeyTask, workDirTask, resolverTask); err != nil {
			return err
		}
		if ops.waitForRootFilesystemResize(rootResizeDone) {
			recorder.add("rolaunch.root-resize-finished")
		}
		recorder.add("rolaunch.userdata-skipped")
		log.Printf("userdata already processed for instance %s, skipping", identity.InstanceID)
		recorder.add("rolaunch.done")
		return nil
	}

	userDataTask := startAsync(func() ([]byte, error) {
		return ops.fetchUserData(ctx, cfg)
	})
	publicKeyTask := startAsync(func() ([]byte, error) {
		key, err := ops.fetchTemporaryPublicKey(ctx, cfg)
		if err != nil {
			return nil, fmt.Errorf("read metadata temporary public key: %w", err)
		}
		return key, nil
	})

	rawUserData, err := userDataTask.wait()
	if err != nil {
		return err
	}
	normalizedUserData := normalizeUserData(rawUserData)
	prefetchTask := startAsync(func() (bool, error) {
		if len(normalizedUserData) == 0 {
			return false, nil
		}
		return ops.prefetchMatchingBootstrap(ctx, cfg, identity.Region, normalizedUserData)
	})

	publicKey, err := publicKeyTask.wait()
	if err != nil {
		return err
	}
	if err := waitAllTasks(hostKeyTask, workDirTask, resolverTask); err != nil {
		return err
	}

	applyTasks := []asyncResult[struct{}]{
		startAsyncTask(func() error {
			return ops.applyLocalAptMirror(identity.Region)
		}),
		startAsyncTask(func() error {
			return ops.installAuthorizedKey(publicKey)
		}),
	}
	if len(normalizedUserData) > 0 {
		applyTasks = append(applyTasks, startAsyncTask(func() error {
			return ops.prepareUserData(cfg.userDataPath, normalizedUserData)
		}))
	}
	if err := waitAllTasks(applyTasks...); err != nil {
		return err
	}
	prefetchedBootstrap, err := prefetchTask.wait()
	if err != nil {
		return err
	}
	if prefetchedBootstrap {
		recorder.add("rolaunch.agent-prefetched")
	}
	recorder.add("rolaunch.bootstrap-ready")

	if len(normalizedUserData) == 0 {
		if ops.waitForRootFilesystemResize(rootResizeDone) {
			recorder.add("rolaunch.root-resize-finished")
		}
		recorder.add("rolaunch.userdata-skipped")
		if err := ops.markDone(cfg.doneMarker, identity.InstanceID); err != nil {
			return err
		}
		log.Printf("empty or unavailable userdata, nothing to execute")
		recorder.add("rolaunch.done")
		return nil
	}

	log.Printf("executing shell userdata: %s", cfg.userDataPath)
	recorder.add("rolaunch.userdata-started")
	err = ops.executeUserData(ctx, cfg)
	if err == nil {
		recorder.add("rolaunch.userdata-finished")
	}
	if ops.waitForRootFilesystemResize(rootResizeDone) {
		recorder.add("rolaunch.root-resize-finished")
	}
	if err != nil {
		if ctx.Err() != nil {
			return fmt.Errorf("executing userdata script: %w", ctx.Err())
		}
		return fmt.Errorf("executing userdata script: %w", err)
	}

	if err := ops.markDone(cfg.doneMarker, identity.InstanceID); err != nil {
		return err
	}

	log.Printf("userdata processed successfully")
	recorder.add("rolaunch.done")
	return nil
}

func startAsync[T any](fn func() (T, error)) asyncResult[T] {
	ch := make(chan taskResult[T], 1)
	go func() {
		value, err := fn()
		ch <- taskResult[T]{value: value, err: err}
		close(ch)
	}()
	return asyncResult[T]{ch: ch}
}

func startAsyncTask(fn func() error) asyncResult[struct{}] {
	return startAsync(func() (struct{}, error) {
		return struct{}{}, fn()
	})
}

func (r asyncResult[T]) wait() (T, error) {
	result := <-r.ch
	return result.value, result.err
}

func waitAllTasks(tasks ...asyncResult[struct{}]) error {
	var firstErr error
	for _, task := range tasks {
		if _, err := task.wait(); err != nil && firstErr == nil {
			firstErr = err
		}
	}
	return firstErr
}

func ensureHostKey() error {
	if _, err := os.Stat(defaultHostKeyPath); err == nil {
		return nil
	} else if !os.IsNotExist(err) {
		return fmt.Errorf("check existing ssh host key: %w", err)
	}

	hostKeyDir := filepath.Dir(defaultHostKeyPath)
	if err := os.MkdirAll(hostKeyDir, 0o755); err != nil {
		return fmt.Errorf("create host key directory: %w", err)
	}

	log.Printf("generating host key at %s", defaultHostKeyPath)
	cmd := exec.Command("ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", defaultHostKeyPath)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("generate ssh host key (%s): %w", defaultHostKeyPath, err)
	}
	return nil
}

func warmupRunnerListener(ctx context.Context) (bool, error) {
	return warmupRunnerListenerAtPath(ctx, defaultRunnerListenerPath)
}

func warmupRunnerListenerAtPath(ctx context.Context, path string) (bool, error) {
	if _, err := os.Stat(path); err != nil {
		if os.IsNotExist(err) {
			return false, fmt.Errorf("runner warmup skipped: %s not found", path)
		}
		return false, fmt.Errorf("runner warmup stat failed for %s: %w", path, err)
	}

	runnerUser, err := lookupCommandUser(defaultRunnerUser)
	if err != nil {
		return false, fmt.Errorf("runner warmup skipped: %w", err)
	}

	command := runnerWarmupCommand(ctx, path, runnerUser)
	out, err := command.CombinedOutput()
	if err != nil {
		text := strings.TrimSpace(string(out))
		if text != "" {
			return false, fmt.Errorf("runner warmup failed: %w (output: %s)", err, text)
		}
		return false, fmt.Errorf("runner warmup failed: %w", err)
	}

	return true, nil
}

type commandUser struct {
	name    string
	uid     uint32
	gid     uint32
	homeDir string
}

func lookupCommandUser(name string) (commandUser, error) {
	account, err := user.Lookup(name)
	if err != nil {
		return commandUser{}, err
	}

	uid, err := strconv.ParseUint(account.Uid, 10, 32)
	if err != nil {
		return commandUser{}, fmt.Errorf("parse %s uid %q: %w", name, account.Uid, err)
	}
	gid, err := strconv.ParseUint(account.Gid, 10, 32)
	if err != nil {
		return commandUser{}, fmt.Errorf("parse %s gid %q: %w", name, account.Gid, err)
	}

	return commandUser{
		name:    account.Username,
		uid:     uint32(uid),
		gid:     uint32(gid),
		homeDir: account.HomeDir,
	}, nil
}

func runnerWarmupCommand(ctx context.Context, path string, runner commandUser) *exec.Cmd {
	command := fmt.Sprintf("%s warmup && rm -rf %s", strconv.Quote(path), strconv.Quote(filepath.Join(runner.homeDir, "_diag")))
	cmd := exec.CommandContext(ctx, "bash", "-lc", command)
	cmd.Dir = runner.homeDir
	cmd.Env = append(os.Environ(),
		"HOME="+runner.homeDir,
		"USER="+runner.name,
		"LOGNAME="+runner.name,
	)
	cmd.SysProcAttr = &syscall.SysProcAttr{
		Credential: &syscall.Credential{
			Uid: runner.uid,
			Gid: runner.gid,
		},
	}
	return cmd
}

func finishWarmupTask(task asyncResult[bool], recorder *timingRecorder) {
	success, err := task.wait()
	if err != nil {
		log.Printf("warning: runner warmup skipped: %v", err)
		return
	}
	if success {
		recorder.add("rolaunch.runner-warmup-finished")
	}
}

func ensureResolverConfig(path string) error {
	current, err := os.ReadFile(path)
	if err == nil && resolverConfigHasEC2Resolver(current) {
		return nil
	}
	if err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("read resolver config (%s): %w", path, err)
	}

	const configBody = "nameserver " + defaultEC2Resolver + "\noptions timeout:1 attempts:5\n"
	if err := os.WriteFile(path, []byte(configBody), 0o644); err != nil {
		return fmt.Errorf("write resolver config (%s): %w", path, err)
	}

	log.Printf("configured resolver %s via %s", defaultEC2Resolver, path)
	return nil
}

func resolverConfigHasEC2Resolver(raw []byte) bool {
	for _, line := range strings.Split(string(raw), "\n") {
		fields := strings.Fields(strings.TrimSpace(line))
		if len(fields) >= 2 && fields[0] == "nameserver" && fields[1] == defaultEC2Resolver {
			return true
		}
	}
	return false
}

func startRootFilesystemResize(ctx context.Context) <-chan rootResizeResult {
	done := make(chan rootResizeResult, 1)
	go func() {
		changed, err := maybeResizeRootFilesystem(ctx)
		done <- rootResizeResult{changed: changed, err: err}
		close(done)
	}()
	return done
}

func waitForRootFilesystemResize(done <-chan rootResizeResult) bool {
	if done == nil {
		return false
	}
	result := <-done
	if result.err != nil {
		log.Printf("warning: root filesystem resize skipped: %v", result.err)
		return false
	}
	return result.changed
}

func maybeResizeRootFilesystem(ctx context.Context) (bool, error) {
	rootPartition, fsType, err := rootMountInfo()
	if err != nil {
		return false, err
	}

	device, partNum, err := parseBlockDevicePartition(rootPartition)
	if err != nil {
		return false, err
	}

	partName := filepath.Base(rootPartition)
	diskName := filepath.Base(device)

	partSize, err := readSysfsSize(partName)
	if err != nil {
		return false, fmt.Errorf("read partition size for %s: %w", partName, err)
	}
	diskSectors, err := readSysfsBlockAttrInt(diskName, "size")
	if err != nil {
		return false, fmt.Errorf("read disk sectors for %s: %w", diskName, err)
	}
	partSectors, err := readSysfsBlockAttrInt(partName, "size")
	if err != nil {
		return false, fmt.Errorf("read partition sectors for %s: %w", partName, err)
	}
	partStartSectors, err := readSysfsStart(partName)
	if err != nil {
		return false, fmt.Errorf("read partition start for %s: %w", partName, err)
	}

	var stat syscall.Statfs_t
	if err := syscall.Statfs("/", &stat); err != nil {
		return false, fmt.Errorf("statfs /: %w", err)
	}
	fsSize := int64(stat.Blocks) * int64(stat.Bsize)

	growableSectors := growableSectorsAtEnd(diskSectors, partStartSectors, partSectors)
	needGrowpart := diskSectors > 0 && partSectors > 0 && growableSectors > diskSectors/100
	needResizeFsByGap := partSize > 0 && fsSize > 0 && (partSize-fsSize) > partSize/100
	needResizeFs := needGrowpart || needResizeFsByGap

	if !needGrowpart && !needResizeFs {
		return false, nil
	}

	log.Printf(
		"root resize needed: root=%s fs=%s part_start=%d part_size=%d fs_size=%d growable=%d needGrowpart=%v needResizeFs=%v",
		rootPartition,
		fsType,
		partStartSectors,
		partSize,
		fsSize,
		growableSectors*512,
		needGrowpart,
		needResizeFs,
	)

	if needGrowpart {
		if _, err := exec.LookPath("growpart"); err != nil {
			return false, fmt.Errorf("growpart not available: %w", err)
		}

		out, err := exec.CommandContext(ctx, "growpart", device, partNum).CombinedOutput()
		text := strings.TrimSpace(string(out))
		if err != nil {
			if strings.Contains(text, "NOCHANGE:") {
				log.Printf("growpart returned NOCHANGE, continuing: %s", text)
			} else {
				return false, fmt.Errorf("growpart %s %s failed: %w (output: %s)", device, partNum, err, text)
			}
		} else if text != "" {
			log.Printf("growpart output: %s", text)
		}

		if _, err := exec.LookPath("udevadm"); err == nil {
			if out, err := exec.CommandContext(ctx, "udevadm", "settle").CombinedOutput(); err != nil {
				log.Printf("warning: udevadm settle failed after growpart: %v (%s)", err, strings.TrimSpace(string(out)))
			}
		}
	}

	if !needResizeFs {
		return true, nil
	}

	var (
		cmdName string
		cmdArgs []string
	)

	switch fsType {
	case "ext2", "ext3", "ext4":
		cmdName = "resize2fs"
		cmdArgs = []string{rootPartition}
	case "xfs":
		cmdName = "xfs_growfs"
		cmdArgs = []string{"/"}
	default:
		log.Printf("warning: unsupported root filesystem %q, skipping resize", fsType)
		return false, nil
	}

	if _, err := exec.LookPath(cmdName); err != nil {
		return false, fmt.Errorf("%s not available: %w", cmdName, err)
	}

	out, err := exec.CommandContext(ctx, cmdName, cmdArgs...).CombinedOutput()
	text := strings.TrimSpace(string(out))
	if err != nil {
		return false, fmt.Errorf("%s failed: %w (output: %s)", cmdName, err, text)
	}
	if text != "" {
		log.Printf("%s output: %s", cmdName, text)
	}

	return true, nil
}

func rootMountInfo() (string, string, error) {
	if out, err := exec.Command("findmnt", "-n", "-o", "SOURCE,FSTYPE", "/").CombinedOutput(); err == nil {
		fields := strings.Fields(strings.TrimSpace(string(out)))
		if len(fields) >= 2 {
			return fields[0], fields[1], nil
		}
	}

	raw, err := os.ReadFile("/proc/mounts")
	if err != nil {
		return "", "", fmt.Errorf("read /proc/mounts: %w", err)
	}

	for _, line := range strings.Split(string(raw), "\n") {
		fields := strings.Fields(line)
		if len(fields) >= 3 && fields[1] == "/" {
			return fields[0], fields[2], nil
		}
	}

	return "", "", fmt.Errorf("root mount not found in /proc/mounts")
}

func parseBlockDevicePartition(rootPartition string) (string, string, error) {
	var matches []string

	if strings.Contains(rootPartition, "nvme") || strings.Contains(rootPartition, "mmcblk") {
		matches = regexp.MustCompile(`^(.+?)(p\d+)$`).FindStringSubmatch(rootPartition)
		if len(matches) == 3 {
			return matches[1], strings.TrimPrefix(matches[2], "p"), nil
		}
	} else {
		matches = regexp.MustCompile(`^(.+?)(\d+)$`).FindStringSubmatch(rootPartition)
		if len(matches) == 3 {
			return matches[1], matches[2], nil
		}
	}

	return "", "", fmt.Errorf("parse root block device %q", rootPartition)
}

func readSysfsBlockAttrInt(name, attr string) (int64, error) {
	data, err := os.ReadFile(filepath.Join("/sys/class/block", name, attr))
	if err != nil {
		return 0, err
	}
	value, err := strconv.ParseInt(strings.TrimSpace(string(data)), 10, 64)
	if err != nil {
		return 0, err
	}
	return value, nil
}

func readSysfsSize(name string) (int64, error) {
	sectors, err := readSysfsBlockAttrInt(name, "size")
	if err != nil {
		return 0, err
	}
	return sectors * 512, nil
}

func readSysfsStart(name string) (int64, error) {
	return readSysfsBlockAttrInt(name, "start")
}

func growableSectorsAtEnd(diskSectors, partStartSectors, partSectors int64) int64 {
	if diskSectors <= 0 || partSectors <= 0 || partStartSectors < 0 {
		return 0
	}

	growable := diskSectors - (partStartSectors + partSectors)
	if growable < 0 {
		return 0
	}

	return growable
}

func applyLocalAptMirror(region string) error {
	mirror := fmt.Sprintf("http://%s.ec2.archive.ubuntu.com/ubuntu", region)
	updatedPaths := make([]string, 0, 2)
	for _, path := range []string{defaultAptSourcesListPath, defaultAptSourcesDeb822} {
		updated, err := rewriteAptSourcesFile(path, mirror)
		if err != nil {
			return err
		}
		if updated {
			updatedPaths = append(updatedPaths, path)
		}
	}

	if len(updatedPaths) > 0 {
		log.Printf("configured apt archive mirror %s in %s", mirror, strings.Join(updatedPaths, ", "))
	}

	return nil
}

func rewriteAptSourcesFile(path string, mirror string) (bool, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return false, nil
		}
		return false, fmt.Errorf("read apt sources (%s): %w", path, err)
	}

	updated, changed := rewriteUbuntuArchiveMirrors(raw, mirror)
	if !changed {
		return false, nil
	}

	if err := os.WriteFile(path, updated, 0o644); err != nil {
		return false, fmt.Errorf("write apt sources (%s): %w", path, err)
	}
	return true, nil
}

func rewriteUbuntuArchiveMirrors(raw []byte, mirror string) ([]byte, bool) {
	updated := ubuntuArchiveMirrorPattern.ReplaceAllString(string(raw), mirror)
	if updated == string(raw) {
		return raw, false
	}
	return []byte(updated), true
}

func installAuthorizedKey(key []byte) error {
	if len(key) == 0 {
		return nil
	}
	key = bytes.TrimSpace(key)
	if len(key) == 0 {
		return nil
	}

	target, err := resolveAuthorizedKeysTarget()
	if err != nil {
		return err
	}

	if err := os.MkdirAll(target.sshDir, 0o700); err != nil {
		return fmt.Errorf("create %s ssh dir: %w", target.userName, err)
	}
	if err := os.Chown(target.sshDir, target.uid, target.gid); err != nil {
		return fmt.Errorf("chown %s ssh dir: %w", target.userName, err)
	}

	existing, err := os.ReadFile(target.path)
	if err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("read authorized_keys: %w", err)
	}

	keyLine := string(key)
	if hasAuthorizedKey(existing, keyLine) {
		return nil
	}

	existing = bytes.TrimRight(existing, "\n")
	if len(existing) > 0 {
		existing = append(existing, '\n')
	}
	updated := append(existing, key...)
	updated = append(updated, '\n')

	if err := os.WriteFile(target.path, updated, 0o600); err != nil {
		return fmt.Errorf("write authorized_keys: %w", err)
	}
	if err := os.Chown(target.path, target.uid, target.gid); err != nil {
		return fmt.Errorf("chown authorized_keys: %w", err)
	}
	return nil
}

func prepareUserData(path string, raw []byte) error {
	if err := validateShellScript(raw); err != nil {
		return fmt.Errorf("unsupported userdata format: %w", err)
	}
	if err := writeScript(path, raw); err != nil {
		return err
	}
	return nil
}

func executeUserDataScript(ctx context.Context, cfg config) error {
	cmd := exec.CommandContext(ctx, cfg.userDataPath)
	cmd.Env = os.Environ()
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func resolveAuthorizedKeysTarget() (authorizedKeysTarget, error) {
	target, err := lookupAuthorizedKeysTarget(defaultUbuntuUser)
	if err == nil {
		return target, nil
	}
	if _, ok := err.(user.UnknownUserError); !ok {
		return authorizedKeysTarget{}, fmt.Errorf("lookup ubuntu user: %w", err)
	}
	return lookupAuthorizedKeysTarget(defaultRootUser)
}

func lookupAuthorizedKeysTarget(name string) (authorizedKeysTarget, error) {
	account, err := user.Lookup(name)
	if err != nil {
		return authorizedKeysTarget{}, err
	}

	uid, err := strconv.Atoi(account.Uid)
	if err != nil {
		return authorizedKeysTarget{}, fmt.Errorf("parse %s uid %q: %w", name, account.Uid, err)
	}
	gid, err := strconv.Atoi(account.Gid)
	if err != nil {
		return authorizedKeysTarget{}, fmt.Errorf("parse %s gid %q: %w", name, account.Gid, err)
	}

	sshDir := filepath.Join(account.HomeDir, ".ssh")
	return authorizedKeysTarget{
		userName: name,
		sshDir:   sshDir,
		path:     filepath.Join(sshDir, "authorized_keys"),
		uid:      uid,
		gid:      gid,
	}, nil
}

func hasAuthorizedKey(existing []byte, candidate string) bool {
	candidate = strings.TrimSpace(candidate)
	if candidate == "" {
		return true
	}
	for _, line := range strings.Split(string(existing), "\n") {
		if strings.TrimSpace(line) == candidate {
			return true
		}
	}
	return false
}

func normalizeUserData(raw []byte) []byte {
	raw = bytes.TrimSuffix(raw, []byte{0})
	raw = bytes.TrimPrefix(raw, []byte{0xef, 0xbb, 0xbf})
	return bytes.TrimSpace(raw)
}

func validateShellScript(raw []byte) error {
	if len(raw) == 0 {
		return fmt.Errorf("empty userdata payload")
	}
	if len(raw) < 2 || raw[0] != '#' || raw[1] != '!' {
		return fmt.Errorf("script must start with #!")
	}
	return nil
}

func writeScript(path string, raw []byte) error {
	if err := os.WriteFile(path, raw, 0o700); err != nil {
		return fmt.Errorf("write userdata script: %w", err)
	}
	if err := os.Chmod(path, 0o700); err != nil {
		return fmt.Errorf("chmod userdata script: %w", err)
	}
	return nil
}

func markerMatchesInstance(path string, instanceID string) (bool, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return false, nil
		}
		return false, fmt.Errorf("read done marker: %w", err)
	}

	markedInstanceID := strings.TrimSpace(string(raw))
	if markedInstanceID == "" || markedInstanceID == "done" {
		log.Printf("ignoring legacy or empty done marker at %s", path)
		return false, nil
	}
	return markedInstanceID == instanceID, nil
}

func markDone(path string, instanceID string) error {
	return os.WriteFile(path, []byte(instanceID+"\n"), 0o600)
}

func newTimingRecorder() *timingRecorder {
	return &timingRecorder{}
}

func (r *timingRecorder) add(name string, at ...time.Time) {
	r.mu.Lock()
	defer r.mu.Unlock()

	stepTime := time.Now().UTC()
	if len(at) > 0 {
		stepTime = at[0]
	}
	r.steps = append(r.steps, Step{Name: name, Time: stepTime})
}

func (r *timingRecorder) save(path string) error {
	if path == "" {
		return nil
	}

	r.mu.Lock()
	steps := append([]Step(nil), r.steps...)
	r.mu.Unlock()

	if len(steps) == 0 {
		return nil
	}

	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("create timings dir: %w", err)
	}

	existing, err := loadTimingSteps(path)
	if err != nil {
		return err
	}

	merged := append(existing, steps...)
	sort.SliceStable(merged, func(i, j int) bool {
		return merged[i].Time.Before(merged[j].Time)
	})

	data, err := json.Marshal(merged)
	if err != nil {
		return fmt.Errorf("marshal timings: %w", err)
	}

	tempFile, err := os.CreateTemp(filepath.Dir(path), filepath.Base(path)+".tmp-*")
	if err != nil {
		return fmt.Errorf("create temp timings file: %w", err)
	}
	tempPath := tempFile.Name()
	defer func() { _ = os.Remove(tempPath) }()

	if _, err := tempFile.Write(data); err != nil {
		_ = tempFile.Close()
		return fmt.Errorf("write temp timings file: %w", err)
	}
	if err := tempFile.Close(); err != nil {
		return fmt.Errorf("close temp timings file: %w", err)
	}
	if err := os.Chmod(tempPath, 0o644); err != nil {
		return fmt.Errorf("chmod temp timings file: %w", err)
	}
	if err := os.Rename(tempPath, path); err != nil {
		return fmt.Errorf("rename timings file: %w", err)
	}
	return nil
}

func loadTimingSteps(path string) ([]Step, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, fmt.Errorf("read timings file: %w", err)
	}

	var steps []Step
	if err := json.Unmarshal(data, &steps); err != nil {
		return nil, fmt.Errorf("decode timings file: %w", err)
	}
	return steps, nil
}
