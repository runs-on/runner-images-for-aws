package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestResolverConfigHasEC2Resolver(t *testing.T) {
	t.Parallel()

	if !resolverConfigHasEC2Resolver([]byte("nameserver " + defaultEC2Resolver + "\n")) {
		t.Fatal("expected resolver config to detect EC2 resolver")
	}
	if resolverConfigHasEC2Resolver([]byte("nameserver 127.0.0.53\n")) {
		t.Fatal("expected non-EC2 resolver to be rejected")
	}
}

func TestEnsureResolverConfigRewritesUnexpectedResolver(t *testing.T) {
	t.Parallel()

	path := filepath.Join(t.TempDir(), "resolv.conf")
	if err := os.WriteFile(path, []byte("nameserver 10.0.0.2\n"), 0o644); err != nil {
		t.Fatalf("write test resolver config: %v", err)
	}

	if err := ensureResolverConfig(path); err != nil {
		t.Fatalf("ensureResolverConfig returned error: %v", err)
	}

	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read rewritten resolver config: %v", err)
	}

	want := "nameserver " + defaultEC2Resolver + "\noptions timeout:1 attempts:5\n"
	if got := string(raw); got != want {
		t.Fatalf("unexpected resolver config contents: %q", got)
	}
}

func TestRewriteUbuntuArchiveMirrorsSourcesList(t *testing.T) {
	t.Parallel()

	raw := []byte("deb http://us-east-1.ec2.archive.ubuntu.com/ubuntu noble main\n" +
		"deb http://security.ubuntu.com/ubuntu noble-security main\n")

	updated, changed := rewriteUbuntuArchiveMirrors(raw, "http://eu-west-3.ec2.archive.ubuntu.com/ubuntu")
	if !changed {
		t.Fatal("expected archive mirror rewrite")
	}

	want := "deb http://eu-west-3.ec2.archive.ubuntu.com/ubuntu noble main\n" +
		"deb http://security.ubuntu.com/ubuntu noble-security main\n"
	if got := string(updated); got != want {
		t.Fatalf("unexpected rewritten sources.list contents: %q", got)
	}
}

func TestRewriteUbuntuArchiveMirrorsDeb822Sources(t *testing.T) {
	t.Parallel()

	raw := []byte("Types: deb\n" +
		"URIs: http://azure.archive.ubuntu.com/ubuntu/\n" +
		"Suites: noble noble-updates noble-backports\n" +
		"Components: main restricted universe multiverse\n" +
		"Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg\n")

	updated, changed := rewriteUbuntuArchiveMirrors(raw, "http://eu-west-3.ec2.archive.ubuntu.com/ubuntu")
	if !changed {
		t.Fatal("expected archive mirror rewrite")
	}

	want := "Types: deb\n" +
		"URIs: http://eu-west-3.ec2.archive.ubuntu.com/ubuntu\n" +
		"Suites: noble noble-updates noble-backports\n" +
		"Components: main restricted universe multiverse\n" +
		"Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg\n"
	if got := string(updated); got != want {
		t.Fatalf("unexpected rewritten ubuntu.sources contents: %q", got)
	}
}

func TestRunFetchesIdentityWithoutWaitingForLocalPrep(t *testing.T) {
	cfg := testConfig(t.TempDir())
	ops := testLauncherOps()

	hostKeyRelease := make(chan struct{})
	hostKeyDone := make(chan struct{})
	warmupRelease := make(chan struct{})
	warmupDone := make(chan struct{})
	identityStarted := make(chan struct{})
	warmupStarted := make(chan struct{})

	ops.ensureHostKey = func() error {
		<-hostKeyRelease
		close(hostKeyDone)
		return nil
	}
	ops.warmupRunner = func(context.Context) (bool, error) {
		close(warmupStarted)
		<-warmupRelease
		close(warmupDone)
		return false, nil
	}
	ops.waitForInstanceIdentity = func(context.Context, config) (instanceIdentity, error) {
		close(identityStarted)
		return instanceIdentity{InstanceID: "i-123", Region: "eu-west-3"}, nil
	}

	runDone := runAsync(func() error {
		return runWithOps(context.Background(), cfg, ops)
	})

	waitForSignal(t, identityStarted, "instance identity fetch start")
	waitForSignal(t, warmupStarted, "runner warmup start")
	assertNotSignaled(t, hostKeyDone, "host key completion")
	assertNotSignaled(t, warmupDone, "runner warmup completion")

	close(hostKeyRelease)
	close(warmupRelease)
	if err := <-runDone; err != nil {
		t.Fatalf("runWithOps returned error: %v", err)
	}
}

func TestRunStartsMetadataFetchesAfterIdentity(t *testing.T) {
	cfg := testConfig(t.TempDir())
	ops := testLauncherOps()

	identityStarted := make(chan struct{})
	userDataStarted := make(chan struct{})
	publicKeyStarted := make(chan struct{})
	releaseIdentity := make(chan struct{})
	releaseMetadata := make(chan struct{})

	ops.waitForInstanceIdentity = func(context.Context, config) (instanceIdentity, error) {
		close(identityStarted)
		<-releaseIdentity
		return instanceIdentity{InstanceID: "i-123", Region: "eu-west-3"}, nil
	}
	ops.fetchUserData = func(context.Context, config) ([]byte, error) {
		close(userDataStarted)
		<-releaseMetadata
		return nil, nil
	}
	ops.fetchTemporaryPublicKey = func(context.Context, config) ([]byte, error) {
		close(publicKeyStarted)
		<-releaseMetadata
		return nil, nil
	}

	runDone := runAsync(func() error {
		return runWithOps(context.Background(), cfg, ops)
	})

	waitForSignal(t, identityStarted, "instance identity fetch")
	assertNotSignaled(t, userDataStarted, "userdata fetch before identity")
	assertNotSignaled(t, publicKeyStarted, "public key fetch before identity")

	close(releaseIdentity)
	waitForSignal(t, userDataStarted, "userdata fetch")
	waitForSignal(t, publicKeyStarted, "public key fetch")

	close(releaseMetadata)
	if err := <-runDone; err != nil {
		t.Fatalf("runWithOps returned error: %v", err)
	}
}

func TestRunCancelsMetadataFetchesWhenMarkerAlreadyMatches(t *testing.T) {
	cfg := testConfig(t.TempDir())
	ops := testLauncherOps()

	unexpectedCalls := make(chan string, 4)

	ops.waitForInstanceIdentity = func(context.Context, config) (instanceIdentity, error) {
		return instanceIdentity{InstanceID: "i-123", Region: "eu-west-3"}, nil
	}
	ops.fetchUserData = func(context.Context, config) ([]byte, error) {
		unexpectedCalls <- "userdata"
		return nil, nil
	}
	ops.fetchTemporaryPublicKey = func(context.Context, config) ([]byte, error) {
		unexpectedCalls <- "public-key"
		return nil, nil
	}
	ops.prefetchMatchingBootstrap = func(context.Context, config, string, []byte) (bool, error) {
		unexpectedCalls <- "prefetch"
		return false, nil
	}
	ops.markerMatchesInstance = func(string, string) (bool, error) {
		return true, nil
	}
	ops.applyLocalAptMirror = func(string) error {
		unexpectedCalls <- "mirror"
		return nil
	}
	ops.installAuthorizedKey = func([]byte) error {
		unexpectedCalls <- "key"
		return nil
	}
	ops.prepareUserData = func(string, []byte) error {
		unexpectedCalls <- "prepare"
		return nil
	}
	ops.executeUserData = func(context.Context, config) error {
		unexpectedCalls <- "execute"
		return nil
	}
	ops.markDone = func(string, string) error {
		unexpectedCalls <- "mark"
		return nil
	}

	if err := runWithOps(context.Background(), cfg, ops); err != nil {
		t.Fatalf("runWithOps returned error: %v", err)
	}

	assertNoUnexpectedCall(t, unexpectedCalls)
}

func TestRunExecutesUserDataOnlyAfterApplyPhaseCompletes(t *testing.T) {
	cfg := testConfig(t.TempDir())
	ops := testLauncherOps()

	mirrorCalled := make(chan struct{})
	keyCalled := make(chan struct{})
	prepareCalled := make(chan struct{})
	executeStarted := make(chan struct{})
	mirrorRelease := make(chan struct{})
	keyRelease := make(chan struct{})
	prepareRelease := make(chan struct{})
	prefetchCalled := make(chan struct{})
	prefetchRelease := make(chan struct{})

	ops.waitForInstanceIdentity = func(context.Context, config) (instanceIdentity, error) {
		return instanceIdentity{InstanceID: "i-123", Region: "eu-west-3"}, nil
	}
	ops.fetchUserData = func(context.Context, config) ([]byte, error) {
		return []byte("#!/bin/sh\necho ok\n"), nil
	}
	ops.fetchTemporaryPublicKey = func(context.Context, config) ([]byte, error) {
		return []byte("ssh-ed25519 AAAA"), nil
	}
	ops.prefetchMatchingBootstrap = func(context.Context, config, string, []byte) (bool, error) {
		close(prefetchCalled)
		<-prefetchRelease
		return true, nil
	}
	ops.applyLocalAptMirror = func(string) error {
		close(mirrorCalled)
		<-mirrorRelease
		return nil
	}
	ops.installAuthorizedKey = func([]byte) error {
		close(keyCalled)
		<-keyRelease
		return nil
	}
	ops.prepareUserData = func(string, []byte) error {
		close(prepareCalled)
		<-prepareRelease
		return nil
	}
	ops.executeUserData = func(context.Context, config) error {
		close(executeStarted)
		return nil
	}

	runDone := runAsync(func() error {
		return runWithOps(context.Background(), cfg, ops)
	})

	waitForSignal(t, mirrorCalled, "apt mirror apply")
	waitForSignal(t, keyCalled, "authorized key install")
	waitForSignal(t, prepareCalled, "userdata preparation")
	waitForSignal(t, prefetchCalled, "bootstrap prefetch")
	assertNotSignaled(t, executeStarted, "userdata execution before apply completion")

	close(mirrorRelease)
	assertNotSignaled(t, executeStarted, "userdata execution after mirror completion")

	close(keyRelease)
	assertNotSignaled(t, executeStarted, "userdata execution after key completion")

	close(prepareRelease)
	assertNotSignaled(t, executeStarted, "userdata execution before prefetch completion")

	close(prefetchRelease)
	waitForSignal(t, executeStarted, "userdata execution")

	if err := <-runDone; err != nil {
		t.Fatalf("runWithOps returned error: %v", err)
	}
}

func TestRunTreatsRootResizeFailureAsWarning(t *testing.T) {
	cfg := testConfig(t.TempDir())
	ops := testLauncherOps()

	var logs bytes.Buffer
	originalWriter := log.Writer()
	originalFlags := log.Flags()
	log.SetOutput(&logs)
	log.SetFlags(0)
	defer func() {
		log.SetOutput(originalWriter)
		log.SetFlags(originalFlags)
	}()

	ops.startRootFilesystemResize = func(context.Context) <-chan rootResizeResult {
		done := make(chan rootResizeResult, 1)
		done <- rootResizeResult{err: fmt.Errorf("resize failed")}
		close(done)
		return done
	}

	if err := runWithOps(context.Background(), cfg, ops); err != nil {
		t.Fatalf("runWithOps returned error: %v", err)
	}
	if !strings.Contains(logs.String(), "warning: root filesystem resize skipped: resize failed") {
		t.Fatalf("expected root resize warning, got %q", logs.String())
	}
}

func TestRunTreatsRunnerWarmupFailureAsWarning(t *testing.T) {
	cfg := testConfig(t.TempDir())
	ops := testLauncherOps()

	var logs bytes.Buffer
	originalWriter := log.Writer()
	originalFlags := log.Flags()
	log.SetOutput(&logs)
	log.SetFlags(0)
	defer func() {
		log.SetOutput(originalWriter)
		log.SetFlags(originalFlags)
	}()

	ops.warmupRunner = func(context.Context) (bool, error) {
		return false, fmt.Errorf("warmup failed")
	}

	if err := runWithOps(context.Background(), cfg, ops); err != nil {
		t.Fatalf("runWithOps returned error: %v", err)
	}
	if !strings.Contains(logs.String(), "warning: runner warmup skipped: warmup failed") {
		t.Fatalf("expected runner warmup warning, got %q", logs.String())
	}
}

func TestRunnerWarmupCommandRunsAsRunnerUser(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	runner := commandUser{
		name:    "runner",
		uid:     1234,
		gid:     2345,
		homeDir: "/home/runner",
	}

	cmd := runnerWarmupCommand(ctx, "/home/runner/bin/Runner.Listener", runner)

	if cmd.Dir != runner.homeDir {
		t.Fatalf("unexpected working dir: got %q want %q", cmd.Dir, runner.homeDir)
	}
	if cmd.SysProcAttr == nil || cmd.SysProcAttr.Credential == nil {
		t.Fatal("expected warmup command credentials to be configured")
	}
	if got := cmd.SysProcAttr.Credential.Uid; got != runner.uid {
		t.Fatalf("unexpected uid: got %d want %d", got, runner.uid)
	}
	if got := cmd.SysProcAttr.Credential.Gid; got != runner.gid {
		t.Fatalf("unexpected gid: got %d want %d", got, runner.gid)
	}
	if !envContains(cmd.Env, "HOME="+runner.homeDir) {
		t.Fatalf("expected HOME override in env: %v", cmd.Env)
	}
	if !envContains(cmd.Env, "USER="+runner.name) {
		t.Fatalf("expected USER override in env: %v", cmd.Env)
	}
	if !envContains(cmd.Env, "LOGNAME="+runner.name) {
		t.Fatalf("expected LOGNAME override in env: %v", cmd.Env)
	}
	if got := strings.Join(cmd.Args, " "); !strings.Contains(got, "Runner.Listener") || !strings.Contains(got, "_diag") {
		t.Fatalf("unexpected warmup command args: %v", cmd.Args)
	}
}

func TestTimingRecorderSaveWritesNewFile(t *testing.T) {
	t.Parallel()

	path := filepath.Join(t.TempDir(), "timings.json")
	recorder := newTimingRecorder()
	recorder.add("rolaunch.started", time.Date(2026, 3, 31, 10, 0, 0, 0, time.UTC))
	recorder.add("rolaunch.done", time.Date(2026, 3, 31, 10, 0, 2, 0, time.UTC))

	if err := recorder.save(path); err != nil {
		t.Fatalf("save returned error: %v", err)
	}

	steps, err := loadTimingSteps(path)
	if err != nil {
		t.Fatalf("loadTimingSteps returned error: %v", err)
	}
	assertStepNames(t, steps, []string{
		"rolaunch.started",
		"rolaunch.done",
	})
}

func TestTimingRecorderSaveMergesExistingAndSorts(t *testing.T) {
	t.Parallel()

	path := filepath.Join(t.TempDir(), "timings.json")
	existing := []Step{
		{Name: "agent-booting", Time: time.Date(2026, 3, 31, 10, 0, 3, 0, time.UTC)},
		{Name: "runner-setup-user", Time: time.Date(2026, 3, 31, 10, 0, 5, 0, time.UTC)},
	}
	raw, err := json.Marshal(existing)
	if err != nil {
		t.Fatalf("marshal existing steps: %v", err)
	}
	if err := os.WriteFile(path, raw, 0o644); err != nil {
		t.Fatalf("write existing timings: %v", err)
	}

	recorder := newTimingRecorder()
	recorder.add("rolaunch.started", time.Date(2026, 3, 31, 10, 0, 1, 0, time.UTC))
	recorder.add("rolaunch.done", time.Date(2026, 3, 31, 10, 0, 4, 0, time.UTC))

	if err := recorder.save(path); err != nil {
		t.Fatalf("save returned error: %v", err)
	}

	steps, err := loadTimingSteps(path)
	if err != nil {
		t.Fatalf("loadTimingSteps returned error: %v", err)
	}
	assertStepNames(t, steps, []string{
		"rolaunch.started",
		"agent-booting",
		"rolaunch.done",
		"runner-setup-user",
	})
}

func TestTimingRecorderSaveReturnsErrorForUnreadablePath(t *testing.T) {
	t.Parallel()

	path := filepath.Join(t.TempDir(), "timings.json")
	if err := os.Mkdir(path, 0o755); err != nil {
		t.Fatalf("mkdir timings path: %v", err)
	}

	recorder := newTimingRecorder()
	recorder.add("rolaunch.started", time.Date(2026, 3, 31, 10, 0, 0, 0, time.UTC))

	if err := recorder.save(path); err == nil {
		t.Fatal("expected save to fail for unreadable timings path")
	}
}

func TestRunPersistsTimingsForNormalUserDataExecution(t *testing.T) {
	t.Parallel()

	cfg := testConfig(t.TempDir())
	ops := testLauncherOps()
	ops.fetchUserData = func(context.Context, config) ([]byte, error) {
		return []byte("#!/bin/sh\necho ok\n"), nil
	}
	ops.fetchTemporaryPublicKey = func(context.Context, config) ([]byte, error) {
		return []byte("ssh-ed25519 AAAA"), nil
	}

	if err := runWithOps(context.Background(), cfg, ops); err != nil {
		t.Fatalf("runWithOps returned error: %v", err)
	}

	steps := mustLoadSteps(t, cfg.timingsPath)
	assertStepSequenceStartsWith(t, steps, "rolaunch.started")
	assertStepSequenceEndsWith(t, steps, "rolaunch.done")
	assertStepsPresent(t, steps, []string{
		"rolaunch.started",
		"rolaunch.imds-ready",
		"rolaunch.host-key-ready",
		"rolaunch.identity-ready",
		"rolaunch.bootstrap-ready",
		"rolaunch.userdata-started",
		"rolaunch.userdata-finished",
		"rolaunch.done",
	})
	assertStepAbsent(t, steps, "rolaunch.userdata-skipped")
	assertStepAbsent(t, steps, "rolaunch.root-resize-finished")
}

func TestRunPersistsTimingsForPrefetchedBootstrap(t *testing.T) {
	t.Parallel()

	cfg := testConfig(t.TempDir())
	ops := testLauncherOps()
	ops.fetchUserData = func(context.Context, config) ([]byte, error) {
		return []byte("#!/bin/sh\necho ok\n"), nil
	}
	ops.prefetchMatchingBootstrap = func(context.Context, config, string, []byte) (bool, error) {
		return true, nil
	}

	if err := runWithOps(context.Background(), cfg, ops); err != nil {
		t.Fatalf("runWithOps returned error: %v", err)
	}

	steps := mustLoadSteps(t, cfg.timingsPath)
	assertStepsPresent(t, steps, []string{
		"rolaunch.agent-prefetched",
		"rolaunch.bootstrap-ready",
	})
}

func TestRunPersistsRunnerWarmupTimingWhenWarmupSucceeds(t *testing.T) {
	t.Parallel()

	cfg := testConfig(t.TempDir())
	ops := testLauncherOps()
	ops.warmupRunner = func(context.Context) (bool, error) {
		return true, nil
	}

	if err := runWithOps(context.Background(), cfg, ops); err != nil {
		t.Fatalf("runWithOps returned error: %v", err)
	}

	steps := mustLoadSteps(t, cfg.timingsPath)
	assertStepsPresent(t, steps, []string{
		"rolaunch.runner-warmup-finished",
	})
}

func TestRunPersistsTimingsWhenMarkerAlreadyMatches(t *testing.T) {
	t.Parallel()

	cfg := testConfig(t.TempDir())
	ops := testLauncherOps()
	ops.markerMatchesInstance = func(string, string) (bool, error) {
		return true, nil
	}

	if err := runWithOps(context.Background(), cfg, ops); err != nil {
		t.Fatalf("runWithOps returned error: %v", err)
	}

	steps := mustLoadSteps(t, cfg.timingsPath)
	assertStepSequenceStartsWith(t, steps, "rolaunch.started")
	assertStepSequenceEndsWith(t, steps, "rolaunch.done")
	assertStepsPresent(t, steps, []string{
		"rolaunch.started",
		"rolaunch.imds-ready",
		"rolaunch.host-key-ready",
		"rolaunch.identity-ready",
		"rolaunch.userdata-skipped",
		"rolaunch.done",
	})
	assertStepAbsent(t, steps, "rolaunch.bootstrap-ready")
}

func TestRunPersistsTimingsForEmptyUserData(t *testing.T) {
	t.Parallel()

	cfg := testConfig(t.TempDir())
	ops := testLauncherOps()

	if err := runWithOps(context.Background(), cfg, ops); err != nil {
		t.Fatalf("runWithOps returned error: %v", err)
	}

	steps := mustLoadSteps(t, cfg.timingsPath)
	assertStepSequenceStartsWith(t, steps, "rolaunch.started")
	assertStepSequenceEndsWith(t, steps, "rolaunch.done")
	assertStepsPresent(t, steps, []string{
		"rolaunch.started",
		"rolaunch.imds-ready",
		"rolaunch.host-key-ready",
		"rolaunch.identity-ready",
		"rolaunch.bootstrap-ready",
		"rolaunch.userdata-skipped",
		"rolaunch.done",
	})
	assertStepAbsent(t, steps, "rolaunch.userdata-started")
	assertStepAbsent(t, steps, "rolaunch.userdata-finished")
}

func TestRunPersistsRootResizeFinishedWhenResizeChangesFilesystem(t *testing.T) {
	t.Parallel()

	cfg := testConfig(t.TempDir())
	ops := testLauncherOps()
	ops.fetchUserData = func(context.Context, config) ([]byte, error) {
		return []byte("#!/bin/sh\necho ok\n"), nil
	}

	resizeDone := make(chan rootResizeResult, 1)
	executeStarted := make(chan struct{})
	allowExecuteFinish := make(chan struct{})

	ops.startRootFilesystemResize = func(context.Context) <-chan rootResizeResult {
		return resizeDone
	}
	ops.executeUserData = func(context.Context, config) error {
		close(executeStarted)
		<-allowExecuteFinish
		return nil
	}

	runDone := runAsync(func() error {
		return runWithOps(context.Background(), cfg, ops)
	})

	waitForSignal(t, executeStarted, "userdata execution")
	close(allowExecuteFinish)

	select {
	case err := <-runDone:
		t.Fatalf("runWithOps returned early: %v", err)
	case <-time.After(100 * time.Millisecond):
	}

	resizeDone <- rootResizeResult{changed: true}
	close(resizeDone)

	if err := <-runDone; err != nil {
		t.Fatalf("runWithOps returned error: %v", err)
	}

	steps := mustLoadSteps(t, cfg.timingsPath)
	assertStepSequenceStartsWith(t, steps, "rolaunch.started")
	assertStepSequenceEndsWith(t, steps, "rolaunch.done")
	assertStepsPresent(t, steps, []string{
		"rolaunch.started",
		"rolaunch.imds-ready",
		"rolaunch.host-key-ready",
		"rolaunch.identity-ready",
		"rolaunch.bootstrap-ready",
		"rolaunch.userdata-started",
		"rolaunch.userdata-finished",
		"rolaunch.root-resize-finished",
		"rolaunch.done",
	})
}

func TestRunIgnoresInvalidExistingTimingsFile(t *testing.T) {
	t.Parallel()

	cfg := testConfig(t.TempDir())
	if err := os.WriteFile(cfg.timingsPath, []byte("{"), 0o644); err != nil {
		t.Fatalf("write invalid timings file: %v", err)
	}

	var logs bytes.Buffer
	originalWriter := log.Writer()
	originalFlags := log.Flags()
	log.SetOutput(&logs)
	log.SetFlags(0)
	defer func() {
		log.SetOutput(originalWriter)
		log.SetFlags(originalFlags)
	}()

	if err := runWithOps(context.Background(), cfg, testLauncherOps()); err != nil {
		t.Fatalf("runWithOps returned error: %v", err)
	}
	if !strings.Contains(logs.String(), "warning: failed to save timing milestones") {
		t.Fatalf("expected timings warning, got %q", logs.String())
	}
}

func TestMarkerMatchesInstance(t *testing.T) {
	t.Parallel()

	path := filepath.Join(t.TempDir(), "done-marker")
	if err := os.WriteFile(path, []byte("i-abc123\n"), 0o600); err != nil {
		t.Fatalf("write marker: %v", err)
	}

	matched, err := markerMatchesInstance(path, "i-abc123")
	if err != nil {
		t.Fatalf("markerMatchesInstance returned error: %v", err)
	}
	if !matched {
		t.Fatal("expected marker to match current instance")
	}

	matched, err = markerMatchesInstance(path, "i-def456")
	if err != nil {
		t.Fatalf("markerMatchesInstance returned error for non-match: %v", err)
	}
	if matched {
		t.Fatal("expected marker not to match different instance")
	}
}

func TestMarkerMatchesInstanceIgnoresLegacyDoneMarker(t *testing.T) {
	t.Parallel()

	path := filepath.Join(t.TempDir(), "done-marker")
	if err := os.WriteFile(path, []byte("done"), 0o600); err != nil {
		t.Fatalf("write legacy marker: %v", err)
	}

	matched, err := markerMatchesInstance(path, "i-abc123")
	if err != nil {
		t.Fatalf("markerMatchesInstance returned error: %v", err)
	}
	if matched {
		t.Fatal("expected legacy marker to be ignored")
	}
}

func TestMarkDoneWritesInstanceID(t *testing.T) {
	t.Parallel()

	path := filepath.Join(t.TempDir(), "done-marker")
	if err := markDone(path, "i-abc123"); err != nil {
		t.Fatalf("markDone returned error: %v", err)
	}

	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read marker: %v", err)
	}
	if got := string(raw); got != "i-abc123\n" {
		t.Fatalf("unexpected marker contents %q", got)
	}
}

func testConfig(workDir string) config {
	return config{
		workDir:      workDir,
		userDataPath: filepath.Join(workDir, defaultUserDataName),
		doneMarker:   filepath.Join(workDir, defaultDoneMarkerName),
		timingsPath:  filepath.Join(workDir, "timings.json"),
	}
}

func testLauncherOps() launcherOps {
	return launcherOps{
		ensureHostKey:        func() error { return nil },
		warmupRunner:         func(context.Context) (bool, error) { return false, nil },
		makeWorkDir:          func(string) error { return nil },
		ensureResolverConfig: func(string) error { return nil },
		waitForInstanceIdentity: func(context.Context, config) (instanceIdentity, error) {
			return instanceIdentity{InstanceID: "i-123", Region: "eu-west-3"}, nil
		},
		fetchUserData: func(context.Context, config) ([]byte, error) {
			return nil, nil
		},
		fetchTemporaryPublicKey: func(context.Context, config) ([]byte, error) {
			return nil, nil
		},
		prefetchMatchingBootstrap: func(context.Context, config, string, []byte) (bool, error) {
			return false, nil
		},
		markerMatchesInstance: func(string, string) (bool, error) {
			return false, nil
		},
		applyLocalAptMirror:  func(string) error { return nil },
		installAuthorizedKey: func([]byte) error { return nil },
		prepareUserData:      func(string, []byte) error { return nil },
		executeUserData:      func(context.Context, config) error { return nil },
		markDone:             func(string, string) error { return nil },
		startRootFilesystemResize: func(context.Context) <-chan rootResizeResult {
			return rootResizeDoneResult(rootResizeResult{})
		},
		waitForRootFilesystemResize: waitForRootFilesystemResize,
	}
}

func rootResizeDoneResult(result rootResizeResult) <-chan rootResizeResult {
	done := make(chan rootResizeResult, 1)
	done <- result
	close(done)
	return done
}

func runAsync(fn func() error) <-chan error {
	done := make(chan error, 1)
	go func() {
		done <- fn()
		close(done)
	}()
	return done
}

func waitForSignal(t *testing.T, ch <-chan struct{}, name string) {
	t.Helper()

	select {
	case <-ch:
	case <-time.After(2 * time.Second):
		t.Fatalf("timed out waiting for %s", name)
	}
}

func assertNotSignaled(t *testing.T, ch <-chan struct{}, name string) {
	t.Helper()

	select {
	case <-ch:
		t.Fatalf("unexpected %s", name)
	default:
	}
}

func assertNoUnexpectedCall(t *testing.T, ch <-chan string) {
	t.Helper()

	select {
	case call := <-ch:
		t.Fatalf("unexpected call to %s", call)
	default:
	}
}

func envContains(env []string, target string) bool {
	for _, entry := range env {
		if entry == target {
			return true
		}
	}
	return false
}

func mustLoadSteps(t *testing.T, path string) []Step {
	t.Helper()

	steps, err := loadTimingSteps(path)
	if err != nil {
		t.Fatalf("loadTimingSteps returned error: %v", err)
	}
	return steps
}

func assertStepNames(t *testing.T, steps []Step, want []string) {
	t.Helper()

	got := make([]string, 0, len(steps))
	for _, step := range steps {
		got = append(got, step.Name)
	}

	if len(got) != len(want) {
		t.Fatalf("unexpected step count: got %v want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("unexpected steps: got %v want %v", got, want)
		}
	}
}

func assertStepsPresent(t *testing.T, steps []Step, want []string) {
	t.Helper()

	for _, name := range want {
		found := false
		for _, step := range steps {
			if step.Name == name {
				found = true
				break
			}
		}
		if !found {
			t.Fatalf("missing step %q in %+v", name, steps)
		}
	}
}

func assertStepSequenceStartsWith(t *testing.T, steps []Step, name string) {
	t.Helper()

	if len(steps) == 0 || steps[0].Name != name {
		t.Fatalf("unexpected first step: got %+v want %q first", steps, name)
	}
}

func assertStepSequenceEndsWith(t *testing.T, steps []Step, name string) {
	t.Helper()

	if len(steps) == 0 || steps[len(steps)-1].Name != name {
		t.Fatalf("unexpected last step: got %+v want %q last", steps, name)
	}
}

func assertStepAbsent(t *testing.T, steps []Step, name string) {
	t.Helper()

	for _, step := range steps {
		if step.Name == name {
			t.Fatalf("unexpected step %q in %+v", name, steps)
		}
	}
}
