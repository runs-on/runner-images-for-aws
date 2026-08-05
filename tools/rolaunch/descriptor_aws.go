package main

import (
	"context"
	"fmt"
	"log"
	"runtime"
	"strings"
)

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
