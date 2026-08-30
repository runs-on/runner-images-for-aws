package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestInstallBakedAgentMissPreservesFallback(t *testing.T) {
	destination := filepath.Join(t.TempDir(), "agent", "agent-linux-x86_64")
	hit, err := installBakedAgent(filepath.Join(t.TempDir(), "missing"), destination)
	if err != nil {
		t.Fatalf("install baked agent: %v", err)
	}
	if hit {
		t.Fatal("missing cache entry reported a hit")
	}
	if _, err := os.Stat(destination); !os.IsNotExist(err) {
		t.Fatalf("destination unexpectedly created: %v", err)
	}
}

func TestInstallBakedAgentPublishesTrustedRegularFile(t *testing.T) {
	root := t.TempDir()
	cachePath := filepath.Join(root, "cache", "agent-linux-x86_64")
	if err := os.MkdirAll(filepath.Dir(cachePath), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(cachePath, []byte("cached-agent"), 0o755); err != nil {
		t.Fatal(err)
	}
	destination := filepath.Join(root, "install", "agent-linux-x86_64")

	hit, err := installBakedAgent(cachePath, destination)
	if err != nil {
		t.Fatalf("install baked agent: %v", err)
	}
	if !hit {
		t.Fatal("trusted cache entry reported a miss")
	}
	body, err := os.ReadFile(destination)
	if err != nil {
		t.Fatal(err)
	}
	if string(body) != "cached-agent" {
		t.Fatalf("destination = %q", body)
	}
	cacheInfo, err := os.Stat(cachePath)
	if err != nil {
		t.Fatal(err)
	}
	destinationInfo, err := os.Stat(destination)
	if err != nil {
		t.Fatal(err)
	}
	if !os.SameFile(cacheInfo, destinationInfo) {
		t.Fatal("same-filesystem cache install did not use an atomic hard link")
	}
}

func TestInstallBakedAgentRejectsMutableOrIndirectEntries(t *testing.T) {
	root := t.TempDir()
	regular := filepath.Join(root, "regular")
	if err := os.WriteFile(regular, []byte("agent"), 0o755); err != nil {
		t.Fatal(err)
	}
	worldWritable := filepath.Join(root, "world-writable")
	if err := os.WriteFile(worldWritable, []byte("agent"), 0o777); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(worldWritable, 0o777); err != nil {
		t.Fatal(err)
	}
	symlink := filepath.Join(root, "symlink")
	if err := os.Symlink(regular, symlink); err != nil {
		t.Fatal(err)
	}

	for name, cachePath := range map[string]string{
		"world-writable": worldWritable,
		"symlink":        symlink,
	} {
		t.Run(name, func(t *testing.T) {
			if hit, err := installBakedAgent(cachePath, filepath.Join(root, "install-"+name)); err == nil || hit {
				t.Fatalf("hit=%v err=%v", hit, err)
			}
		})
	}
}
