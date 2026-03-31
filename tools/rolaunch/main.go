package main

import (
	"bytes"
	"context"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const (
	defaultIMDSEndpoint       = "http://169.254.169.254"
	imdsTokenPath             = "/latest/api/token"
	imdsUserDataPath          = "/latest/user-data"
	imdsPublicKeysPath        = "/latest/meta-data/public-keys"
	imdsInstanceIDPath        = "/latest/meta-data/instance-id"
	imdsPlacementRegionPath   = "/latest/meta-data/placement/region"
	imdsTokenTTLSecs          = "21600"
	maxIMDSErrorBodyBytes     = 2048
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
	defaultReadinessTimeout   = 5 * time.Minute
	defaultReadinessInterval  = 250 * time.Millisecond
	defaultIMDSRequestTimeout = 5 * time.Second
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
	client       *http.Client
}

type authorizedKeysTarget struct {
	userName string
	sshDir   string
	path     string
	uid      int
	gid      int
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
		client: &http.Client{
			Timeout: defaultIMDSRequestTimeout,
		},
	}

	ctx, cancel := context.WithTimeout(context.Background(), cfg.timeout)
	defer cancel()

	if err := run(ctx, cfg); err != nil {
		log.Fatalf("rolaunch failed: %v", err)
	}
}

func run(ctx context.Context, cfg config) error {
	if err := ensureHostKey(); err != nil {
		return err
	}

	rootResizeDone := startRootFilesystemResize(ctx)

	if err := os.MkdirAll(cfg.workDir, 0o700); err != nil {
		return fmt.Errorf("create workdir: %w", err)
	}

	if err := ensureResolverConfig(defaultResolverConfigPath); err != nil {
		return err
	}

	token, err := waitForReadinessAndFetchToken(ctx, cfg)
	if err != nil {
		return err
	}

	instanceID, err := fetchInstanceID(ctx, cfg, token)
	if err != nil {
		return fmt.Errorf("discover instance id: %w", err)
	}

	alreadyProcessed, err := markerMatchesInstance(cfg.doneMarker, instanceID)
	if err != nil {
		return err
	}
	if alreadyProcessed {
		waitForRootFilesystemResize(rootResizeDone)
		log.Printf("userdata already processed for instance %s, skipping", instanceID)
		return nil
	}

	if err := ensureLocalAptMirror(ctx, cfg, token); err != nil {
		return err
	}

	if err := installTemporaryPublicKey(ctx, cfg, token); err != nil {
		return err
	}

	raw, err := fetchUserData(ctx, cfg, token)
	if err != nil {
		return err
	}

	raw = normalizeUserData(raw)
	if len(raw) == 0 {
		waitForRootFilesystemResize(rootResizeDone)
		if err := markDone(cfg.doneMarker, instanceID); err != nil {
			return err
		}
		log.Printf("empty or unavailable userdata, nothing to execute")
		return nil
	}

	if err := validateShellScript(raw); err != nil {
		return fmt.Errorf("unsupported userdata format: %w", err)
	}

	if err := writeScript(cfg.userDataPath, raw); err != nil {
		return err
	}
	log.Printf("executing shell userdata: %s", cfg.userDataPath)

	cmd := exec.CommandContext(ctx, cfg.userDataPath)
	cmd.Env = os.Environ()
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr

	err = cmd.Run()
	waitForRootFilesystemResize(rootResizeDone)
	if err != nil {
		if ctx.Err() != nil {
			return fmt.Errorf("executing userdata script: %w", ctx.Err())
		}
		return fmt.Errorf("executing userdata script: %w", err)
	}

	if err := markDone(cfg.doneMarker, instanceID); err != nil {
		return err
	}

	log.Printf("userdata processed successfully")
	return nil
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

func startRootFilesystemResize(ctx context.Context) <-chan error {
	done := make(chan error, 1)
	go func() {
		done <- maybeResizeRootFilesystem(ctx)
		close(done)
	}()
	return done
}

func waitForRootFilesystemResize(done <-chan error) {
	if done == nil {
		return
	}
	if err := <-done; err != nil {
		log.Printf("warning: root filesystem resize skipped: %v", err)
	}
}

func maybeResizeRootFilesystem(ctx context.Context) error {
	rootPartition, fsType, err := rootMountInfo()
	if err != nil {
		return err
	}

	device, partNum, err := parseBlockDevicePartition(rootPartition)
	if err != nil {
		return err
	}

	partName := filepath.Base(rootPartition)
	diskName := filepath.Base(device)

	partSize, err := readSysfsSize(partName)
	if err != nil {
		return fmt.Errorf("read partition size for %s: %w", partName, err)
	}
	diskSectors, err := readSysfsBlockAttrInt(diskName, "size")
	if err != nil {
		return fmt.Errorf("read disk sectors for %s: %w", diskName, err)
	}
	partSectors, err := readSysfsBlockAttrInt(partName, "size")
	if err != nil {
		return fmt.Errorf("read partition sectors for %s: %w", partName, err)
	}
	partStartSectors, err := readSysfsStart(partName)
	if err != nil {
		return fmt.Errorf("read partition start for %s: %w", partName, err)
	}

	var stat syscall.Statfs_t
	if err := syscall.Statfs("/", &stat); err != nil {
		return fmt.Errorf("statfs /: %w", err)
	}
	fsSize := int64(stat.Blocks) * int64(stat.Bsize)

	growableSectors := growableSectorsAtEnd(diskSectors, partStartSectors, partSectors)
	needGrowpart := diskSectors > 0 && partSectors > 0 && growableSectors > diskSectors/100
	needResizeFsByGap := partSize > 0 && fsSize > 0 && (partSize-fsSize) > partSize/100
	needResizeFs := needGrowpart || needResizeFsByGap

	if !needGrowpart && !needResizeFs {
		return nil
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
			return fmt.Errorf("growpart not available: %w", err)
		}

		out, err := exec.CommandContext(ctx, "growpart", device, partNum).CombinedOutput()
		text := strings.TrimSpace(string(out))
		if err != nil {
			if strings.Contains(text, "NOCHANGE:") {
				log.Printf("growpart returned NOCHANGE, continuing: %s", text)
			} else {
				return fmt.Errorf("growpart %s %s failed: %w (output: %s)", device, partNum, err, text)
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
		return nil
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
		return nil
	}

	if _, err := exec.LookPath(cmdName); err != nil {
		return fmt.Errorf("%s not available: %w", cmdName, err)
	}

	out, err := exec.CommandContext(ctx, cmdName, cmdArgs...).CombinedOutput()
	text := strings.TrimSpace(string(out))
	if err != nil {
		return fmt.Errorf("%s failed: %w (output: %s)", cmdName, err, text)
	}
	if text != "" {
		log.Printf("%s output: %s", cmdName, text)
	}

	return nil
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

func waitForReadinessAndFetchToken(ctx context.Context, cfg config) (string, error) {
	ticker := time.NewTicker(defaultReadinessInterval)
	defer ticker.Stop()
	loggedWaiting := false

	for {
		if ctx.Err() != nil {
			return "", fmt.Errorf("timed out waiting for IMDSv2: %w", ctx.Err())
		}

		token, err := fetchImdsToken(ctx, cfg)
		if err == nil {
			return token, nil
		}
		if !loggedWaiting {
			log.Printf("waiting for IMDSv2 availability: %v", err)
			loggedWaiting = true
		}

		select {
		case <-ctx.Done():
			return "", fmt.Errorf("timed out waiting for IMDSv2: %w", ctx.Err())
		case <-ticker.C:
			continue
		}
	}
}

func fetchImdsToken(ctx context.Context, cfg config) (string, error) {
	url := strings.TrimRight(cfg.imdsBase, "/") + imdsTokenPath
	req, err := http.NewRequestWithContext(ctx, http.MethodPut, url, nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("X-aws-ec2-metadata-token-ttl-seconds", imdsTokenTTLSecs)

	resp, err := cfg.client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, maxIMDSErrorBodyBytes))
		bodyText := strings.TrimSpace(string(body))
		if bodyText != "" {
			return "", fmt.Errorf("IMDS token request returned %d: %s", resp.StatusCode, bodyText)
		}
		return "", fmt.Errorf("IMDS token request returned %d", resp.StatusCode)
	}

	token, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", fmt.Errorf("read IMDS token response: %w", err)
	}

	tokenStr := strings.TrimSpace(string(token))
	if tokenStr == "" {
		return "", fmt.Errorf("received empty IMDS token")
	}
	return tokenStr, nil
}

func ensureLocalAptMirror(ctx context.Context, cfg config, token string) error {
	region, err := fetchInstanceRegion(ctx, cfg, token)
	if err != nil {
		return fmt.Errorf("discover instance region for apt mirror: %w", err)
	}

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

func fetchInstanceID(ctx context.Context, cfg config, token string) (string, error) {
	instanceID, status, err := fetchIMDSWithToken(ctx, cfg, token, strings.TrimRight(cfg.imdsBase, "/")+imdsInstanceIDPath)
	if err != nil {
		return "", err
	}
	if status != http.StatusOK {
		return "", fmt.Errorf("instance-id request returned %d", status)
	}

	trimmed := strings.TrimSpace(string(instanceID))
	if trimmed == "" {
		return "", fmt.Errorf("received empty instance-id from IMDS")
	}
	return trimmed, nil
}

func fetchInstanceRegion(ctx context.Context, cfg config, token string) (string, error) {
	region, status, err := fetchIMDSWithToken(ctx, cfg, token, strings.TrimRight(cfg.imdsBase, "/")+imdsPlacementRegionPath)
	if err != nil {
		return "", err
	}
	if status == http.StatusOK {
		trimmed := strings.TrimSpace(string(region))
		if trimmed == "" {
			return "", fmt.Errorf("received empty placement region from IMDS")
		}
		return trimmed, nil
	}
	return "", fmt.Errorf("placement region request returned %d", status)
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

func fetchUserData(ctx context.Context, cfg config, token string) ([]byte, error) {
	url := strings.TrimRight(cfg.imdsBase, "/") + imdsUserDataPath
	body, status, err := fetchIMDSWithToken(ctx, cfg, token, url)
	if err != nil {
		return nil, err
	}
	switch status {
	case http.StatusNotFound:
		return nil, nil
	case http.StatusOK:
		return body, nil
	default:
		bodyText := strings.TrimSpace(string(body))
		if bodyText != "" {
			return nil, fmt.Errorf("userdata request returned %d: %s", status, bodyText)
		}
		return nil, fmt.Errorf("userdata request returned %d", status)
	}
}

func installTemporaryPublicKey(ctx context.Context, cfg config, token string) error {
	key, err := fetchTemporaryPublicKey(ctx, cfg, token)
	if err != nil {
		return fmt.Errorf("read metadata temporary public key: %w", err)
	}
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

func fetchTemporaryPublicKey(ctx context.Context, cfg config, token string) ([]byte, error) {
	raw, status, err := fetchIMDSPublicKey(ctx, cfg, token, "0")
	if err == nil && status == http.StatusOK && len(bytes.TrimSpace(raw)) > 0 {
		return raw, nil
	}
	if err != nil {
		return nil, err
	}

	index, found, err := discoverPublicKeyIndex(ctx, cfg, token)
	if err != nil {
		return nil, err
	}
	if !found {
		return nil, nil
	}

	raw, status, err = fetchIMDSPublicKey(ctx, cfg, token, index)
	if err != nil {
		return nil, err
	}
	if status != http.StatusOK {
		if status == http.StatusNotFound {
			return nil, nil
		}
		return nil, fmt.Errorf("public-key fetch returned %d", status)
	}
	return raw, nil
}

func fetchIMDSPublicKey(ctx context.Context, cfg config, token string, index string) ([]byte, int, error) {
	path := fmt.Sprintf("%s/%s/openssh-key", imdsPublicKeysPath, index)
	return fetchIMDSWithToken(ctx, cfg, token, strings.TrimRight(cfg.imdsBase, "/")+path)
}

func discoverPublicKeyIndex(ctx context.Context, cfg config, token string) (string, bool, error) {
	body, status, err := fetchIMDSWithToken(ctx, cfg, token, strings.TrimRight(cfg.imdsBase, "/")+imdsPublicKeysPath+"/")
	if err != nil {
		return "", false, err
	}
	if status == http.StatusNotFound {
		return "", false, nil
	}
	if status != http.StatusOK {
		return "", false, fmt.Errorf("public-key index request returned %d", status)
	}

	for _, line := range strings.Split(string(bytes.TrimSpace(body)), "\n") {
		parts := strings.SplitN(strings.TrimSpace(line), "=", 2)
		if len(parts) == 2 && parts[0] != "" {
			return parts[0], true, nil
		}
	}
	return "", false, nil
}

func fetchIMDSWithToken(ctx context.Context, cfg config, token string, url string) ([]byte, int, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, 0, err
	}
	req.Header.Set("X-aws-ec2-metadata-token", token)

	resp, err := cfg.client.Do(req)
	if err != nil {
		return nil, 0, err
	}
	defer resp.Body.Close()

	var reader io.Reader = resp.Body
	if resp.StatusCode != http.StatusOK {
		reader = io.LimitReader(resp.Body, maxIMDSErrorBodyBytes)
	}

	body, err := io.ReadAll(reader)
	if err != nil {
		return nil, 0, fmt.Errorf("read IMDS response: %w", err)
	}

	if resp.StatusCode == http.StatusOK {
		return body, http.StatusOK, nil
	}
	return body, resp.StatusCode, nil
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
