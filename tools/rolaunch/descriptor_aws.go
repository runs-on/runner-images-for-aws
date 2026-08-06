package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
)

const defaultBakedAgentCacheRoot = "/opt/runs-on/agent-cache"

var bakedAgentCacheRoot = defaultBakedAgentCacheRoot

func currentGOARCH() string {
	return runtime.GOARCH
}

func (s *awsState) prefetchDescriptorAgent(ctx context.Context, cfg config, region string, raw []byte) (bool, error) {
	descriptor, matched, err := parseBootstrapDescriptor(raw)
	if err != nil || !matched {
		return matched, err
	}
	marker("rolaunch.descriptor-discovered", "", "agent")
	spec, err := descriptorAgentSpec(descriptor)
	if err != nil {
		return true, err
	}
	cachePath := filepath.Join(bakedAgentCacheRoot, descriptor.Agent.Bucket, filepath.FromSlash(spec.S3Key))
	cacheHit, err := installBakedAgent(cachePath, spec.DownloadedBinPath)
	if err != nil {
		return true, fmt.Errorf("install baked agent cache entry: %w", err)
	}
	if cacheHit {
		if err := installDescriptorBootstrapWrapper(spec.BootstrapPath, spec.DownloadedBinPath); err != nil {
			return true, err
		}
		marker("rolaunch.agent-cache-hit", "", spec.AgentBinaryName)
		log.Printf("installed baked RunsOn agent cache entry %s to %s", cachePath, spec.DownloadedBinPath)
		return true, nil
	}

	summary := pollSummary{}
	var object fetchedObject
	for {
		if ctx.Err() != nil {
			return true, fmt.Errorf("startup deadline fetching agent s3://%s/%s: %w", spec.S3Bucket, spec.S3Key, ctx.Err())
		}
		summary.attempts++
		client, clientErr := s.retriableS3Client(ctx, cfg, region)
		if clientErr != nil {
			summary.transient++
			waitForPollRetry(ctx, summary.attempts)
			continue
		}
		object, err = fetchS3Object(ctx, client, spec.S3Bucket, spec.S3Key)
		if err == nil {
			break
		}
		status := s3StatusCode(err)
		switch {
		case status == 404:
			summary.notFound++
		case status == 403:
			summary.forbidden++
			if summary.forbidden >= 3 {
				return true, fmt.Errorf("persistent 403 fetching agent s3://%s/%s", spec.S3Bucket, spec.S3Key)
			}
		case status == 0 || status >= 500:
			summary.transient++
		default:
			return true, fmt.Errorf("non-retriable error fetching agent s3://%s/%s: %w", spec.S3Bucket, spec.S3Key, err)
		}
		waitForPollRetry(ctx, summary.attempts)
	}
	if len(object.body) == 0 {
		return true, fmt.Errorf("agent object s3://%s/%s is empty", spec.S3Bucket, spec.S3Key)
	}
	if err := writeAtomicFile(spec.DownloadedBinPath, object.body, 0o700); err != nil {
		return true, fmt.Errorf("install prefetched agent: %w", err)
	}
	if err := installDescriptorBootstrapWrapper(spec.BootstrapPath, spec.DownloadedBinPath); err != nil {
		return true, err
	}

	marker("rolaunch.agent-published", "", spec.AgentBinaryName)
	log.Printf("prefetched RunsOn agent from s3://%s/%s to %s (attempts=%d not_found=%d transient=%d forbidden=%d)", spec.S3Bucket, spec.S3Key, spec.DownloadedBinPath, summary.attempts, summary.notFound, summary.transient, summary.forbidden)
	return true, nil
}

// installBakedAgent atomically hard-links an immutable, image-baked artifact
// into rolaunch's per-version directory. A missing cache entry is a normal
// miss and preserves the existing S3 download path. The cache is trusted only
// when it is a regular, executable file that cannot be modified by non-root
// users.
func installBakedAgent(cachePath, destination string) (bool, error) {
	info, err := os.Lstat(cachePath)
	if os.IsNotExist(err) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 {
		return false, fmt.Errorf("cache entry is not a regular file: %s", cachePath)
	}
	if info.Mode().Perm()&0o111 == 0 || info.Mode().Perm()&0o022 != 0 {
		return false, fmt.Errorf("cache entry must be executable and not group/world writable: %s", cachePath)
	}

	dir := filepath.Dir(destination)
	if strings.HasPrefix(destination, defaultWorkDir+string(os.PathSeparator)) {
		if err := secureDirectory(dir); err != nil {
			return false, err
		}
	} else if err := os.MkdirAll(dir, 0o755); err != nil {
		return false, err
	}
	if existing, err := os.Lstat(destination); err == nil && (!existing.Mode().IsRegular() || existing.Mode()&os.ModeSymlink != 0) {
		return false, fmt.Errorf("refusing to replace non-regular file %s", destination)
	} else if err != nil && !os.IsNotExist(err) {
		return false, err
	}

	temp, err := os.CreateTemp(dir, ".rolaunch-cache-*")
	if err != nil {
		return false, err
	}
	tempPath := temp.Name()
	if err := temp.Close(); err != nil {
		os.Remove(tempPath)
		return false, err
	}
	if err := os.Remove(tempPath); err != nil {
		return false, err
	}
	defer os.Remove(tempPath)
	if err := os.Link(cachePath, tempPath); err != nil {
		if errors.Is(err, syscall.EXDEV) {
			body, readErr := os.ReadFile(cachePath)
			if readErr != nil {
				return false, readErr
			}
			if writeErr := writeAtomicFile(destination, body, info.Mode().Perm()); writeErr != nil {
				return false, writeErr
			}
			return true, nil
		}
		return false, err
	}
	if err := os.Rename(tempPath, destination); err != nil {
		return false, err
	}
	dirFile, err := os.Open(dir)
	if err != nil {
		return false, err
	}
	defer dirFile.Close()
	if err := dirFile.Sync(); err != nil {
		return false, err
	}
	return true, nil
}

func (s *awsState) prefetchDescriptorConfigs(ctx context.Context, cfg config, identity instanceIdentity, raw []byte) error {
	descriptor, matched, err := parseBootstrapDescriptor(raw)
	if err != nil || !matched {
		return err
	}
	marker("rolaunch.descriptor-discovered", identity.InstanceID, "configs")
	return prefetchConfigObjects(ctx, s, cfg, identity, descriptor)
}

// The old client cache remembers bootstrap failures. Clear only that failed
// entry so a later poll can recover without disturbing successfully built clients.
func (s *awsState) retriableS3Client(ctx context.Context, cfg config, region string) (s3ObjectGetter, error) {
	return s.s3ClientFor(ctx, cfg, region)
}

func installDescriptorBootstrapWrapper(path string, downloadedAgentPath string) error {
	body := []byte("#!/bin/bash\nset -euo pipefail\nexec " + shellQuote(downloadedAgentPath) + "\n")
	if err := writeAtomicFile(path, body, 0o755); err != nil {
		return fmt.Errorf("install bootstrap wrapper %s: %w", path, err)
	}
	return nil
}

func shellQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "'\\''") + "'"
}
