//go:build windows

package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"time"

	"golang.org/x/sys/windows/registry"
	"golang.org/x/sys/windows/svc"
	"golang.org/x/sys/windows/svc/mgr"
)

const serviceName = "RunsOnLaunch"

type windowsOps struct {
	httpClient *http.Client
	stateDir   string
}

type commandProcess struct {
	command *exec.Cmd
	logFile *os.File
}

func (p commandProcess) Wait() error {
	err := p.command.Wait()
	closeErr := p.logFile.Close()
	if err != nil {
		return err
	}
	return closeErr
}

func (o *windowsOps) bootID() (string, error) {
	key, err := registry.OpenKey(registry.LOCAL_MACHINE, `SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters`, registry.QUERY_VALUE)
	if err != nil {
		return "", err
	}
	defer key.Close()
	value, _, err := key.GetIntegerValue("BootId")
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("%d", value), nil
}

func (o *windowsOps) fetchUserData(ctx context.Context) (string, []byte, error) {
	deadline, cancel := context.WithTimeout(ctx, 3*time.Minute)
	defer cancel()
	for {
		token, err := o.imdsRequest(deadline, http.MethodPut, "/latest/api/token", "")
		if err == nil {
			identityRaw, identityErr := o.imdsRequest(deadline, http.MethodGet, "/latest/dynamic/instance-identity/document", string(token))
			if identityErr == nil {
				var identity struct {
					InstanceID string `json:"instanceId"`
				}
				if err := json.Unmarshal(identityRaw, &identity); err != nil {
					return "", nil, fmt.Errorf("parse instance identity: %w", err)
				}
				userData, userDataErr := o.imdsRequest(deadline, http.MethodGet, "/latest/user-data", string(token))
				if userDataErr != nil {
					return identity.InstanceID, nil, userDataErr
				}
				return identity.InstanceID, userData, nil
			}
		}
		select {
		case <-deadline.Done():
			return "", nil, deadline.Err()
		case <-time.After(50 * time.Millisecond):
		}
	}
}

func (o *windowsOps) imdsRequest(ctx context.Context, method, path, token string) ([]byte, error) {
	request, err := http.NewRequestWithContext(ctx, method, "http://169.254.169.254"+path, nil)
	if err != nil {
		return nil, err
	}
	if method == http.MethodPut {
		request.Header.Set("X-aws-ec2-metadata-token-ttl-seconds", "21600")
	} else {
		request.Header.Set("X-aws-ec2-metadata-token", token)
	}
	response, err := o.httpClient.Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	body, err := io.ReadAll(io.LimitReader(response.Body, 1<<20))
	if err != nil {
		return nil, err
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return nil, fmt.Errorf("IMDS %s %s returned %s: %s", method, path, response.Status, body)
	}
	return body, nil
}

func (o *windowsOps) claim(bootID string) (bool, error) {
	path := filepath.Join(o.stateDir, "claims", bootID)
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return false, err
	}
	file, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if errors.Is(err, os.ErrExist) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return true, file.Close()
}

func (o *windowsOps) releaseClaim(bootID string) error {
	err := os.Remove(filepath.Join(o.stateDir, "claims", bootID))
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	return err
}

func (o *windowsOps) startBootstrap(ctx context.Context, path string, args []string, environment []string) (process, error) {
	command := exec.CommandContext(ctx, path, args...)
	command.Env = environment
	logPath := filepath.Join(o.stateDir, "bootstrap.log")
	if err := os.MkdirAll(filepath.Dir(logPath), 0o700); err != nil {
		return nil, err
	}
	logFile, err := os.OpenFile(logPath, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return nil, err
	}
	command.Stdout = logFile
	command.Stderr = logFile
	if err := command.Start(); err != nil {
		logFile.Close()
		return nil, err
	}
	return commandProcess{command: command, logFile: logFile}, nil
}

func (o *windowsOps) startSSM() error {
	manager, err := mgr.Connect()
	if err != nil {
		return err
	}
	defer manager.Disconnect()
	service, err := manager.OpenService("AmazonSSMAgent")
	if err != nil {
		return err
	}
	defer service.Close()
	status, err := service.Query()
	if err == nil && (status.State == svc.Running || status.State == svc.StartPending) {
		return nil
	}
	if err := service.Start(); err != nil {
		return err
	}
	return nil
}

func (o *windowsOps) writeState(state launchState) error {
	return writeJSONAtomic(filepath.Join(o.stateDir, "timings.json"), state)
}

type serviceHandler struct{ ops *windowsOps }

func (h serviceHandler) Execute(_ []string, requests <-chan svc.ChangeRequest, statuses chan<- svc.Status) (bool, uint32) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	statuses <- svc.Status{State: svc.StartPending}
	statuses <- svc.Status{State: svc.Running, Accepts: svc.AcceptStop | svc.AcceptShutdown}

	done := make(chan error, 1)
	go func() { done <- runLauncher(ctx, h.ops) }()
	for {
		select {
		case request := <-requests:
			switch request.Cmd {
			case svc.Interrogate:
				statuses <- request.CurrentStatus
			case svc.Stop, svc.Shutdown:
				statuses <- svc.Status{State: svc.StopPending}
				cancel()
				return false, 0
			}
		case err := <-done:
			if err != nil {
				return false, 1
			}
			return false, 0
		}
	}
}

func main() {
	runOnce := flag.Bool("run-once", false, "run in the foreground instead of the Windows service manager")
	flag.Parse()
	ops := &windowsOps{httpClient: &http.Client{Timeout: 2 * time.Second}, stateDir: defaultStateDirectory}
	if *runOnce {
		if err := runLauncher(context.Background(), ops); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		return
	}
	if err := svc.Run(serviceName, serviceHandler{ops: ops}); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
