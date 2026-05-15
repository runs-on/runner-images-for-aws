package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

func saveInstanceIdentity(path string, identity instanceIdentity) error {
	if path == "" {
		return nil
	}

	data, err := json.Marshal(identity)
	if err != nil {
		return fmt.Errorf("marshal instance identity: %w", err)
	}

	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("create instance identity dir: %w", err)
	}

	tempFile, err := os.CreateTemp(filepath.Dir(path), filepath.Base(path)+".tmp-*")
	if err != nil {
		return fmt.Errorf("create temp instance identity file: %w", err)
	}
	tempPath := tempFile.Name()
	defer func() { _ = os.Remove(tempPath) }()

	if _, err := tempFile.Write(data); err != nil {
		_ = tempFile.Close()
		return fmt.Errorf("write temp instance identity file: %w", err)
	}
	if err := tempFile.Close(); err != nil {
		return fmt.Errorf("close temp instance identity file: %w", err)
	}
	if err := os.Chmod(tempPath, 0o600); err != nil {
		return fmt.Errorf("chmod temp instance identity file: %w", err)
	}
	if err := os.Rename(tempPath, path); err != nil {
		return fmt.Errorf("rename instance identity file: %w", err)
	}
	return nil
}

func loadInstanceIdentity(path string) (instanceIdentity, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return instanceIdentity{}, fmt.Errorf("read instance identity file: %w", err)
	}

	var identity instanceIdentity
	if err := json.Unmarshal(data, &identity); err != nil {
		return instanceIdentity{}, fmt.Errorf("decode instance identity file: %w", err)
	}
	return identity, nil
}
