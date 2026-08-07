package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

type fakeProcess struct{ err error }

func (p fakeProcess) Wait() error { return p.err }

type fakeOps struct {
	boot          string
	instanceID    string
	userData      []byte
	claimed       bool
	bootstrapPath string
	bootstrapArgs []string
	bootstrapEnv  []string
	bootstrapErr  error
	processErr    error
	ssmStarts     int
	claimReleases int
	states        []launchState
}

func (o *fakeOps) bootID() (string, error) { return o.boot, nil }
func (o *fakeOps) fetchUserData(context.Context) (string, []byte, error) {
	return o.instanceID, o.userData, nil
}
func (o *fakeOps) claim(string) (bool, error) { return o.claimed, nil }
func (o *fakeOps) releaseClaim(string) error  { o.claimReleases++; return nil }
func (o *fakeOps) startBootstrap(_ context.Context, path string, args []string, environment []string) (process, error) {
	o.bootstrapPath = path
	o.bootstrapArgs = append([]string(nil), args...)
	o.bootstrapEnv = append([]string(nil), environment...)
	if o.bootstrapErr != nil {
		return nil, o.bootstrapErr
	}
	return fakeProcess{err: o.processErr}, nil
}
func (o *fakeOps) startSSM() error { o.ssmStarts++; return nil }
func (o *fakeOps) writeState(state launchState) error {
	copyOfState := state
	copyOfState.Milestones = append([]milestone(nil), state.Milestones...)
	o.states = append(o.states, copyOfState)
	return nil
}

func encodedUserData(t *testing.T, descriptor launchDescriptor) []byte {
	t.Helper()
	raw, err := json.Marshal(descriptor)
	if err != nil {
		t.Fatal(err)
	}
	return []byte("<powershell>\n" + descriptorPrefix + base64.RawStdEncoding.EncodeToString(raw) + "\n</powershell>\n")
}

func validDescriptor() launchDescriptor {
	return launchDescriptor{
		Version:          1,
		BootstrapVersion: "v0.1.17",
		AgentS3URL:       "s3://runs-on/agent-windows-AMD64.exe",
		PostExec:         "shutdown",
		Environment: map[string]string{
			"AWS_REGION":                 "us-east-1",
			"RUNS_ON_RUNNER_MAX_RUNTIME": "3600",
		},
	}
}

func TestParseLaunchDescriptor(t *testing.T) {
	descriptor, err := parseLaunchDescriptor(encodedUserData(t, validDescriptor()))
	if err != nil {
		t.Fatal(err)
	}
	if descriptor.BootstrapVersion != "v0.1.17" {
		t.Fatalf("unexpected bootstrap version %q", descriptor.BootstrapVersion)
	}
}

func TestDescriptorRejectsUnapprovedEnvironment(t *testing.T) {
	descriptor := validDescriptor()
	descriptor.Environment["PATH"] = `C:\untrusted`
	_, err := parseLaunchDescriptor(encodedUserData(t, descriptor))
	if err == nil || !strings.Contains(err.Error(), "not allowed") {
		t.Fatalf("expected allowlist error, got %v", err)
	}
}

func TestRunLauncherStartsBootstrapBeforeSSM(t *testing.T) {
	ops := &fakeOps{
		boot:       "42",
		instanceID: "i-test",
		userData:   encodedUserData(t, validDescriptor()),
		claimed:    true,
	}
	if err := runLauncher(context.Background(), ops); err != nil {
		t.Fatal(err)
	}
	if ops.ssmStarts != 1 {
		t.Fatalf("expected one SSM start, got %d", ops.ssmStarts)
	}
	if !strings.HasSuffix(ops.bootstrapPath, `bootstrap-v0.1.17.exe`) {
		t.Fatalf("unexpected bootstrap path %q", ops.bootstrapPath)
	}
	if got := strings.Join(ops.bootstrapArgs, " "); got != "--debug=false --exec --post-exec shutdown s3://runs-on/agent-windows-AMD64.exe" {
		t.Fatalf("unexpected bootstrap arguments %q", got)
	}
	final := ops.states[len(ops.states)-1]
	if final.Status != "complete" {
		t.Fatalf("unexpected final status %q", final.Status)
	}
	names := make([]string, 0, len(final.Milestones))
	for _, item := range final.Milestones {
		names = append(names, item.Name)
	}
	bootstrapIndex, ssmIndex := -1, -1
	for index, name := range names {
		if name == "runs-on-launch.bootstrap-started" {
			bootstrapIndex = index
		}
		if name == "runs-on-launch.ssm-started" {
			ssmIndex = index
		}
	}
	if bootstrapIndex < 0 || ssmIndex <= bootstrapIndex {
		t.Fatalf("RunsOn must precede SSM, milestones=%v", names)
	}
}

func TestRunLauncherStartsSSMOnFailure(t *testing.T) {
	ops := &fakeOps{
		boot:         "42",
		instanceID:   "i-test",
		userData:     encodedUserData(t, validDescriptor()),
		claimed:      true,
		bootstrapErr: errors.New("boom"),
	}
	if err := runLauncher(context.Background(), ops); err == nil {
		t.Fatal("expected bootstrap failure")
	}
	if ops.ssmStarts != 1 {
		t.Fatalf("expected diagnostic SSM start, got %d", ops.ssmStarts)
	}
	if ops.claimReleases != 1 {
		t.Fatalf("expected failed start to release claim, got %d", ops.claimReleases)
	}
}

func TestRunLauncherDoesNotDuplicateClaimedBoot(t *testing.T) {
	ops := &fakeOps{
		boot:       "42",
		instanceID: "i-test",
		userData:   encodedUserData(t, validDescriptor()),
		claimed:    false,
	}
	if err := runLauncher(context.Background(), ops); err != nil {
		t.Fatal(err)
	}
	if ops.bootstrapPath != "" || ops.ssmStarts != 0 || len(ops.states) != 0 {
		t.Fatalf("claimed boot launched work: path=%q ssm=%d", ops.bootstrapPath, ops.ssmStarts)
	}
}

func TestLaunchEnvironmentReplacesExistingValuesCaseInsensitively(t *testing.T) {
	environment := launchEnvironment(
		[]string{"Path=C:\\Windows", "aws_region=old", "KEEP=value"},
		map[string]string{"AWS_REGION": "us-east-1"},
	)
	joined := strings.Join(environment, "\n")
	if strings.Contains(joined, "aws_region=old") {
		t.Fatalf("old environment value survived: %v", environment)
	}
	if !strings.Contains(joined, "AWS_REGION=us-east-1") || !strings.Contains(joined, "KEEP=value") {
		t.Fatalf("environment merge lost values: %v", environment)
	}
}
