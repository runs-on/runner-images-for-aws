package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

const (
	defaultStateDirectory = `C:\ProgramData\RunsOn\Launch`
	defaultBootstrapDir   = `C:\runs-on`
)

type milestone struct {
	Name string    `json:"name"`
	Time time.Time `json:"time"`
}

type launchState struct {
	BootID     string      `json:"boot_id"`
	InstanceID string      `json:"instance_id,omitempty"`
	Status     string      `json:"status"`
	Error      string      `json:"error,omitempty"`
	Milestones []milestone `json:"milestones"`
}

type launcherOps interface {
	bootID() (string, error)
	fetchUserData(context.Context) (instanceID string, userData []byte, err error)
	claim(string) (bool, error)
	releaseClaim(string) error
	startBootstrap(context.Context, string, []string, []string) (process, error)
	startSSM() error
	writeState(launchState) error
}

type process interface {
	Wait() error
}

func runLauncher(ctx context.Context, ops launcherOps) error {
	state := launchState{Status: "starting"}
	record := func(name string) {
		state.Milestones = append(state.Milestones, milestone{Name: name, Time: time.Now().UTC()})
	}
	persist := func() {
		_ = ops.writeState(state)
	}
	fail := func(err error) error {
		state.Status = "failed"
		state.Error = err.Error()
		record("runs-on-launch.failed")
		persist()
		_ = ops.startSSM()
		return err
	}

	record("runs-on-launch.started")
	bootID, err := ops.bootID()
	if err != nil {
		return fail(fmt.Errorf("resolve boot id: %w", err))
	}
	state.BootID = bootID

	instanceID, userData, err := ops.fetchUserData(ctx)
	if err != nil {
		return fail(fmt.Errorf("fetch IMDS user data: %w", err))
	}
	state.InstanceID = instanceID
	record("runs-on-launch.imds-ready")

	descriptor, err := parseLaunchDescriptor(userData)
	if err != nil {
		return fail(err)
	}
	record("runs-on-launch.descriptor-ready")

	claimed, err := ops.claim(bootID)
	if err != nil {
		return fail(fmt.Errorf("claim boot execution: %w", err))
	}
	if !claimed {
		return nil
	}
	record("runs-on-launch.claimed")
	persist()

	bootstrapPath := filepath.Join(defaultBootstrapDir, "bootstrap-"+descriptor.BootstrapVersion+".exe")
	args := []string{"--debug=" + fmt.Sprintf("%t", descriptor.Debug), "--exec"}
	if descriptor.PostExec != "" {
		args = append(args, "--post-exec", descriptor.PostExec)
	}
	args = append(args, descriptor.AgentS3URL)

	environment := launchEnvironment(os.Environ(), descriptor.Environment)

	child, err := ops.startBootstrap(ctx, bootstrapPath, args, environment)
	if err != nil {
		_ = ops.releaseClaim(bootID)
		return fail(fmt.Errorf("start RunsOn bootstrap: %w", err))
	}
	state.Status = "bootstrap-running"
	record("runs-on-launch.bootstrap-started")
	persist()

	if err := ops.startSSM(); err != nil {
		state.Error = fmt.Sprintf("start SSM: %v", err)
		record("runs-on-launch.ssm-failed")
		persist()
	} else {
		record("runs-on-launch.ssm-started")
		persist()
	}

	if err := child.Wait(); err != nil {
		return fail(fmt.Errorf("RunsOn bootstrap exited: %w", err))
	}
	state.Status = "complete"
	record("runs-on-launch.bootstrap-finished")
	persist()
	return nil
}

func launchEnvironment(base []string, additions map[string]string) []string {
	environment := make([]string, 0, len(base)+len(additions))
	for _, item := range base {
		name, _, found := strings.Cut(item, "=")
		if !found {
			continue
		}
		if _, replaces := additions[strings.ToUpper(name)]; !replaces {
			environment = append(environment, item)
		}
	}
	names := make([]string, 0, len(additions))
	for name := range additions {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		environment = append(environment, name+"="+additions[name])
	}
	return environment
}

func writeJSONAtomic(path string, value any) error {
	raw, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	temporary := path + ".tmp"
	if err := os.WriteFile(temporary, append(raw, '\n'), 0o600); err != nil {
		return err
	}
	return os.Rename(temporary, path)
}
