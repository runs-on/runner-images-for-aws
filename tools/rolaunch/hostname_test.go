package main

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

func TestHostnameForInstanceUsesIMDSLocalHostnameModes(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name     string
		identity instanceIdentity
		hostname string
	}{
		{
			name: "IP-based name",
			identity: instanceIdentity{
				LocalHostname: "ip-10-0-0-1.us-east-1.compute.internal",
				PrivateIP:     "10.0.0.1",
				InstanceID:    "i-0123456789abcdef0",
			},
			hostname: "ip-10-0-0-1",
		},
		{
			name: "resource-based name",
			identity: instanceIdentity{
				LocalHostname: "i-0123456789abcdef0.ec2.internal",
				PrivateIP:     "10.0.0.1",
				InstanceID:    "i-0123456789abcdef0",
			},
			hostname: "i-0123456789abcdef0",
		},
		{
			name: "IPv6-only resource-based name",
			identity: instanceIdentity{
				LocalHostname: "i-0fedcba9876543210.ec2.internal.",
				InstanceID:    "i-0fedcba9876543210",
			},
			hostname: "i-0fedcba9876543210",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			hostname, err := hostnameForInstance(test.identity)
			if err != nil {
				t.Fatalf("hostnameForInstance returned error: %v", err)
			}
			if hostname != test.hostname {
				t.Fatalf("unexpected hostname %q, want %q", hostname, test.hostname)
			}
		})
	}
}

func TestHostnameForInstanceFallsBackSafely(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name     string
		identity instanceIdentity
		want     string
	}{
		{
			name:     "IPv4 identity document",
			identity: instanceIdentity{LocalHostname: "unsafe/name", PrivateIP: " 10.0.0.1 ", InstanceID: "i-123"},
			want:     "ip-10-0-0-1",
		},
		{
			name:     "instance ID for IPv6-only identity",
			identity: instanceIdentity{PrivateIP: "2001:db8::1", InstanceID: "i-0123456789abcdef0"},
			want:     "i-0123456789abcdef0",
		},
		{
			name:     "IPv6 address when instance ID is unusable",
			identity: instanceIdentity{PrivateIP: "2001:db8::1", InstanceID: "invalid/id"},
			want:     "ip6-20010db8000000000000000000000001",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			got, err := hostnameForInstance(test.identity)
			if err != nil {
				t.Fatalf("hostnameForInstance returned error: %v", err)
			}
			if got != test.want {
				t.Fatalf("unexpected hostname %q, want %q", got, test.want)
			}
		})
	}
}

func TestHostnameForInstanceRejectsUnusableIdentity(t *testing.T) {
	t.Parallel()

	if _, err := hostnameForInstance(instanceIdentity{LocalHostname: "unsafe/name", PrivateIP: "not-an-ip", InstanceID: "invalid/id"}); err == nil {
		t.Fatal("expected unusable identity to be rejected")
	}
}

func TestMetadataHostnameLabelRejectsUnsafeValues(t *testing.T) {
	t.Parallel()

	for _, value := range []string{"", "-host.ec2.internal", "host_name.ec2.internal", "host..internal", "host\nother.internal"} {
		if _, ok := metadataHostnameLabel(value); ok {
			t.Fatalf("expected %q to be rejected", value)
		}
	}
}

func TestConfigureInstanceHostnameReplacesBuilderHostname(t *testing.T) {
	t.Parallel()

	dir := t.TempDir()
	hostnamePath := filepath.Join(dir, "hostname")
	hostsPath := filepath.Join(dir, "hosts")
	mustWriteFile(t, hostnamePath, "packer-builder\n", 0o644)
	mustWriteFile(t, hostsPath, "127.0.0.1 localhost\n127.0.1.1 packer-builder packer-builder.local custom-alias # stale\n127.0.1.1 duplicate-builder\n::1 localhost ip6-localhost ip6-loopback\n", 0o644)

	var runtimeHostname string
	err := configureInstanceHostnameAtPaths(
		instanceIdentity{PrivateIP: "10.0.0.1", InstanceID: "i-123"},
		hostnamePath,
		hostsPath,
		func() (string, error) { return "packer-builder", nil },
		func(hostname string) error {
			runtimeHostname = hostname
			return nil
		},
	)
	if err != nil {
		t.Fatalf("configureInstanceHostnameAtPaths returned error: %v", err)
	}

	assertFileContents(t, hostnamePath, "ip-10-0-0-1\n")
	assertFileContents(t, hostsPath, "127.0.0.1 localhost\n127.0.1.1 ip-10-0-0-1 custom-alias # stale\n127.0.1.1 duplicate-builder\n::1 localhost ip6-localhost ip6-loopback\n")
	if runtimeHostname != "ip-10-0-0-1" {
		t.Fatalf("unexpected runtime hostname %q", runtimeHostname)
	}
}

func TestConfigureInstanceHostnameAddsLocalhostMappings(t *testing.T) {
	t.Parallel()

	dir := t.TempDir()
	hostnamePath := filepath.Join(dir, "hostname")
	hostsPath := filepath.Join(dir, "hosts")
	mustWriteFile(t, hostsPath, "::1 localhost ip6-localhost ip6-loopback\n", 0o644)

	err := configureInstanceHostnameAtPaths(
		instanceIdentity{PrivateIP: "10.20.30.40", InstanceID: "i-123"},
		hostnamePath,
		hostsPath,
		func() (string, error) { return "builder", nil },
		func(string) error { return nil },
	)
	if err != nil {
		t.Fatalf("configureInstanceHostnameAtPaths returned error: %v", err)
	}

	assertFileContents(t, hostnamePath, "ip-10-20-30-40\n")
	assertFileContents(t, hostsPath, "127.0.0.1 localhost\n::1 localhost ip6-localhost ip6-loopback\n127.0.1.1 ip-10-20-30-40\n")
}

func TestConfigureInstanceHostnameReplacesPriorInstanceNameWithResourceBasedName(t *testing.T) {
	t.Parallel()

	dir := t.TempDir()
	hostnamePath := filepath.Join(dir, "hostname")
	hostsPath := filepath.Join(dir, "hosts")
	mustWriteFile(t, hostnamePath, "ip-10-0-0-1\n", 0o644)
	mustWriteFile(t, hostsPath, "127.0.0.1 localhost\n127.0.1.1 ip-10-0-0-1 ip-10-0-0-1.ec2.internal runner-alias\n", 0o644)

	var runtimeHostname string
	err := configureInstanceHostnameAtPaths(
		instanceIdentity{
			LocalHostname: "i-0123456789abcdef0.ec2.internal",
			PrivateIP:     "10.0.0.1",
			InstanceID:    "i-0123456789abcdef0",
		},
		hostnamePath,
		hostsPath,
		func() (string, error) { return "ip-10-0-0-1", nil },
		func(hostname string) error {
			runtimeHostname = hostname
			return nil
		},
	)
	if err != nil {
		t.Fatalf("configureInstanceHostnameAtPaths returned error: %v", err)
	}

	assertFileContents(t, hostnamePath, "i-0123456789abcdef0\n")
	assertFileContents(t, hostsPath, "127.0.0.1 localhost\n127.0.1.1 i-0123456789abcdef0 runner-alias\n")
	if runtimeHostname != "i-0123456789abcdef0" {
		t.Fatalf("unexpected runtime hostname %q", runtimeHostname)
	}
}

func TestConfigureInstanceHostnameIsIdempotent(t *testing.T) {
	t.Parallel()

	dir := t.TempDir()
	hostnamePath := filepath.Join(dir, "hostname")
	hostsPath := filepath.Join(dir, "hosts")
	mustWriteFile(t, hostnamePath, "ip-10-0-0-1\n", 0o444)
	mustWriteFile(t, hostsPath, "127.0.0.1 localhost\n127.0.1.1 ip-10-0-0-1\n", 0o444)

	err := configureInstanceHostnameAtPaths(
		instanceIdentity{PrivateIP: "10.0.0.1", InstanceID: "i-123"},
		hostnamePath,
		hostsPath,
		func() (string, error) { return "ip-10-0-0-1", nil },
		func(string) error { return fmt.Errorf("runtime hostname setter must not run") },
	)
	if err != nil {
		t.Fatalf("idempotent configuration returned error: %v", err)
	}
}

func TestConfigureInstanceHostnamePreservesAliasesAfterInitialSetup(t *testing.T) {
	t.Parallel()

	dir := t.TempDir()
	hostnamePath := filepath.Join(dir, "hostname")
	hostsPath := filepath.Join(dir, "hosts")
	mustWriteFile(t, hostnamePath, "ip-10-0-0-1\n", 0o644)
	hosts := "127.0.0.1 localhost\n127.0.1.1 ip-10-0-0-1 custom-alias # retained\n127.0.1.1 another-alias\n"
	mustWriteFile(t, hostsPath, hosts, 0o644)

	err := configureInstanceHostnameAtPaths(
		instanceIdentity{PrivateIP: "10.0.0.1", InstanceID: "i-123"},
		hostnamePath,
		hostsPath,
		func() (string, error) { return "ip-10-0-0-1", nil },
		func(string) error { return fmt.Errorf("runtime hostname setter must not run") },
	)
	if err != nil {
		t.Fatalf("idempotent configuration returned error: %v", err)
	}

	assertFileContents(t, hostsPath, hosts)
}

func TestRunWaitsForHostnameBeforeExecutingUserData(t *testing.T) {
	cfg := testConfig(t.TempDir())
	cfg.mode = launchModeFull
	ops := testLauncherOps()
	hostnameStarted := make(chan struct{})
	hostnameRelease := make(chan struct{})
	userDataStarted := make(chan struct{})

	ops.waitForInstanceIdentity = func(context.Context, config) (instanceIdentity, error) {
		return instanceIdentity{InstanceID: "i-123", Region: "eu-west-3", PrivateIP: "10.0.0.1"}, nil
	}
	ops.configureInstanceHostname = func(instanceIdentity) error {
		close(hostnameStarted)
		<-hostnameRelease
		return nil
	}
	ops.fetchUserData = func(context.Context, config) ([]byte, error) {
		return []byte("#!/bin/sh\necho ok\n"), nil
	}
	ops.executeUserData = func(context.Context, config) error {
		close(userDataStarted)
		return nil
	}

	runDone := runAsync(func() error {
		return runWithOps(context.Background(), cfg, ops)
	})

	waitForSignal(t, hostnameStarted, "hostname configuration")
	assertNotSignaled(t, userDataStarted, "userdata execution before hostname configuration")
	close(hostnameRelease)
	waitForSignal(t, userDataStarted, "userdata execution")
	if err := <-runDone; err != nil {
		t.Fatalf("runWithOps returned error: %v", err)
	}
}

func TestRunMinimalModeDoesNotConfigureInstanceHostname(t *testing.T) {
	cfg := testConfig(t.TempDir())
	ops := testLauncherOps()
	ops.configureInstanceHostname = func(instanceIdentity) error {
		return fmt.Errorf("minimal mode must not configure the hostname")
	}

	if err := runWithOps(context.Background(), cfg, ops); err != nil {
		t.Fatalf("runWithOps returned error: %v", err)
	}
}

func mustWriteFile(t *testing.T, path string, content string, mode os.FileMode) {
	t.Helper()
	if err := os.WriteFile(path, []byte(content), mode); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}

func assertFileContents(t *testing.T, path string, want string) {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	if got := string(raw); got != want {
		t.Fatalf("unexpected %s contents:\ngot:  %q\nwant: %q", path, got, want)
	}
}
