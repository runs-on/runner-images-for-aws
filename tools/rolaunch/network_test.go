package main

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"reflect"
	"syscall"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws/retry"
	"github.com/aws/aws-sdk-go-v2/feature/ec2/imds"
)

func TestReadNetworkLinksReportsKernelAndNetworkdState(t *testing.T) {
	t.Parallel()

	root := t.TempDir()
	sysClassNet := filepath.Join(root, "sys", "class", "net")
	networkdLinks := filepath.Join(root, "run", "systemd", "netif", "links")
	writeTestFile(t, filepath.Join(sysClassNet, "lo", "ifindex"), "1\n")
	writeTestFile(t, filepath.Join(sysClassNet, "enp39s0", "ifindex"), "2\n")
	writeTestFile(t, filepath.Join(sysClassNet, "enp39s0", "operstate"), "down\n")
	writeTestFile(t, filepath.Join(sysClassNet, "enp39s0", "carrier"), "1\n")
	driverDir := filepath.Join(root, "sys", "bus", "pci", "drivers", "ena")
	if err := os.MkdirAll(driverDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(sysClassNet, "enp39s0", "device"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(driverDir, filepath.Join(sysClassNet, "enp39s0", "device", "driver")); err != nil {
		t.Fatal(err)
	}
	writeTestFile(t, filepath.Join(networkdLinks, "2"), "# This is private data.\nADMIN_STATE=failed\nOPER_STATE=off\n")

	links := readNetworkLinks(sysClassNet, networkdLinks)

	want := []networkLink{{
		Name:          "enp39s0",
		Index:         "2",
		Driver:        "ena",
		OperState:     "down",
		Carrier:       "1",
		NetworkdAdmin: "failed",
		NetworkdOper:  "off",
	}}
	if !reflect.DeepEqual(links, want) {
		t.Fatalf("unexpected links: got %+v, want %+v", links, want)
	}
	if got := describeNetworkLinks(links); got != "enp39s0(ifindex=2 driver=ena operstate=down carrier=1 networkd=failed/off)" {
		t.Fatalf("unexpected description %q", got)
	}
}

func TestReadNetworkLinksWithoutInterfaces(t *testing.T) {
	t.Parallel()

	links := readNetworkLinks(filepath.Join(t.TempDir(), "missing"), t.TempDir())
	if len(links) != 0 {
		t.Fatalf("expected no links, got %+v", links)
	}
	if got := describeNetworkLinks(links); got != "no network interfaces" {
		t.Fatalf("unexpected description %q", got)
	}
}

func TestNetworkRecoveryCommand(t *testing.T) {
	t.Parallel()

	got := networkRecoveryCommand([]networkLink{{Name: "enp39s0"}})
	if want := []string{"networkctl", "reconfigure", "enp39s0"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("unexpected command with links: %v", got)
	}

	got = networkRecoveryCommand(nil)
	want := []string{"udevadm", "trigger", "--action=add", "--subsystem-match=pci", "--attr-match=class=0x020000"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("unexpected command without links: %v", got)
	}
}

func TestNetworkWatchdogLogsAndRecoversOnSchedule(t *testing.T) {
	t.Parallel()

	reads := 0
	var commands [][]string
	watchdog := &networkWatchdog{
		readLinks: func() []networkLink {
			reads++
			return []networkLink{{Name: "enp39s0"}}
		},
		runCommand: func(_ context.Context, command []string) error {
			commands = append(commands, command)
			return errors.New("ignored")
		},
		logEvery:     10 * time.Second,
		recoverAfter: 15 * time.Second,
		recoverEvery: 30 * time.Second,
	}

	start := time.Unix(0, 0)
	errUnreachable := fmt.Errorf("dial: %w", syscall.ENETUNREACH)
	for elapsed := time.Duration(0); elapsed <= 50*time.Second; elapsed += 50 * time.Millisecond {
		watchdog.observe(context.Background(), start.Add(elapsed), errUnreachable)
	}

	// Logs at 10s, 20s, 30s, 40s, 50s; recoveries at 15s and 45s.
	if reads != 7 {
		t.Fatalf("expected 7 link reads, got %d", reads)
	}
	want := [][]string{
		{"networkctl", "reconfigure", "enp39s0"},
		{"networkctl", "reconfigure", "enp39s0"},
	}
	if !reflect.DeepEqual(commands, want) {
		t.Fatalf("unexpected recovery commands: %v", commands)
	}
}

func TestNetworkWatchdogLeavesLinksAloneOnOtherIMDSErrors(t *testing.T) {
	t.Parallel()

	watchdog := &networkWatchdog{
		readLinks: func() []networkLink { return []networkLink{{Name: "enp39s0"}} },
		runCommand: func(context.Context, []string) error {
			t.Fatal("recovery must not run when IMDS is reachable")
			return nil
		},
		logEvery:     10 * time.Second,
		recoverAfter: 15 * time.Second,
		recoverEvery: 30 * time.Second,
	}

	start := time.Unix(0, 0)
	errHTTP := errors.New("operation error ec2imds: GetInstanceIdentityDocument, http response error StatusCode: 500")
	for elapsed := time.Duration(0); elapsed <= time.Minute; elapsed += time.Second {
		watchdog.observe(context.Background(), start.Add(elapsed), errHTTP)
	}
}

func TestNetworkWatchdogBoundsAStuckRecoveryCommand(t *testing.T) {
	t.Parallel()

	watchdog := &networkWatchdog{
		readLinks: func() []networkLink { return []networkLink{{Name: "enp39s0"}} },
		runCommand: func(ctx context.Context, _ []string) error {
			return runNetworkRecoveryCommand(ctx, []string{"sleep", "30"})
		},
		logEvery:       time.Hour,
		recoverAfter:   time.Second,
		recoverEvery:   time.Hour,
		recoverTimeout: 100 * time.Millisecond,
	}

	start := time.Unix(0, 0)
	errUnreachable := fmt.Errorf("dial: %w", syscall.ENETUNREACH)
	watchdog.observe(context.Background(), start, errUnreachable)
	began := time.Now()
	watchdog.observe(context.Background(), start.Add(2*time.Second), errUnreachable)
	if elapsed := time.Since(began); elapsed > 3*time.Second {
		t.Fatalf("stuck recovery command held the readiness loop for %s", elapsed)
	}
}

// The SDK must keep the dial errno reachable through its error wrapping, or
// recovery would never run on the boots it exists for.
func TestIMDSDialErrorIsNetworkUnreachable(t *testing.T) {
	t.Parallel()

	state := newAWSState()
	state.metadataClient = imds.New(imds.Options{
		ClientEnableState:        imds.ClientEnabled,
		Endpoint:                 defaultIMDSEndpoint,
		Retryer:                  retry.AddWithMaxAttempts(retry.NewStandard(), 1),
		DisableDefaultMaxBackoff: true,
		HTTPClient:               &http.Client{Transport: unreachableTransport{}},
	})

	for attempt := 0; attempt < 2; attempt++ {
		_, err := state.fetchInstanceIdentity(context.Background(), config{mode: launchModeFull})
		if !isNetworkUnreachable(err) {
			t.Fatalf("attempt %d: expected network unreachable, got %v", attempt, err)
		}
	}
}

type unreachableTransport struct{}

func (unreachableTransport) RoundTrip(*http.Request) (*http.Response, error) {
	return nil, &net.OpError{Op: "dial", Net: "tcp", Err: os.NewSyscallError("connect", syscall.ENETUNREACH)}
}

func writeTestFile(t *testing.T, path, body string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}
