package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"

	aws "github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/aws/retry"
	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/feature/ec2/imds"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	smithyhttp "github.com/aws/smithy-go/transport/http"
)

const (
	imdsPublicKeysMetadataPath = "public-keys"
	imdsPublicKeySuffix        = "openssh-key"
)

type awsState struct {
	mu             sync.Mutex
	metadataClient *imds.Client
	s3Clients      map[string]*s3.Client
	s3Errors       map[string]error
}

type bootstrapPrefetchSpec struct {
	BootstrapTag      string
	BootstrapPath     string
	AgentBinaryName   string
	S3Bucket          string
	S3Key             string
	DownloadedBinPath string
}

func newAWSState() *awsState {
	return &awsState{
		s3Clients: make(map[string]*s3.Client),
		s3Errors:  make(map[string]error),
	}
}

func (s *awsState) waitForReadinessAndFetchIdentity(ctx context.Context, cfg config) (instanceIdentity, error) {
	ticker := time.NewTicker(defaultReadinessInterval)
	defer ticker.Stop()
	loggedWaiting := false

	for {
		if ctx.Err() != nil {
			return instanceIdentity{}, fmt.Errorf("timed out waiting for IMDSv2: %w", ctx.Err())
		}

		identity, err := s.fetchInstanceIdentity(ctx, cfg)
		if err == nil {
			return identity, nil
		}
		if !loggedWaiting {
			log.Printf("waiting for IMDS instance identity availability: %v", err)
			loggedWaiting = true
		}

		select {
		case <-ctx.Done():
			return instanceIdentity{}, fmt.Errorf("timed out waiting for IMDSv2: %w", ctx.Err())
		case <-ticker.C:
		}
	}
}

func (s *awsState) fetchInstanceIdentity(ctx context.Context, cfg config) (instanceIdentity, error) {
	client := s.metadataClientFor(cfg)

	output, err := client.GetInstanceIdentityDocument(ctx, &imds.GetInstanceIdentityDocumentInput{})
	if err != nil {
		return instanceIdentity{}, err
	}

	identity := instanceIdentity{
		DevpayProductCodes:      append([]string(nil), output.DevpayProductCodes...),
		MarketplaceProductCodes: append([]string(nil), output.MarketplaceProductCodes...),
		AvailabilityZone:        strings.TrimSpace(output.AvailabilityZone),
		PrivateIP:               strings.TrimSpace(output.PrivateIP),
		Version:                 strings.TrimSpace(output.Version),
		Region:                  strings.TrimSpace(output.Region),
		InstanceID:              strings.TrimSpace(output.InstanceID),
		BillingProducts:         append([]string(nil), output.BillingProducts...),
		InstanceType:            strings.TrimSpace(output.InstanceType),
		AccountID:               strings.TrimSpace(output.AccountID),
		PendingTime:             output.PendingTime,
		ImageID:                 strings.TrimSpace(output.ImageID),
		KernelID:                strings.TrimSpace(output.KernelID),
		RamdiskID:               strings.TrimSpace(output.RamdiskID),
		Architecture:            strings.TrimSpace(output.Architecture),
	}
	if identity.InstanceID == "" {
		return instanceIdentity{}, fmt.Errorf("received empty instance-id from IMDS")
	}
	if identity.Region == "" {
		return instanceIdentity{}, fmt.Errorf("received empty region from IMDS")
	}

	return identity, nil
}

func (s *awsState) enrichOptionalInstanceIdentity(ctx context.Context, cfg config, identity instanceIdentity) (instanceIdentity, error) {
	if body, found, err := s.fetchMetadataPath(ctx, cfg, "public-ipv4"); err == nil {
		value := ""
		if found {
			value = strings.TrimSpace(string(body))
		}
		identity.PublicIPv4 = &value
	} else {
		return instanceIdentity{}, err
	}

	if body, found, err := s.fetchMetadataPath(ctx, cfg, "instance-life-cycle"); err == nil {
		value := ""
		if found {
			value = strings.TrimSpace(string(body))
		}
		identity.InstanceLifecycle = &value
	} else {
		return instanceIdentity{}, err
	}

	return identity, nil
}

func (s *awsState) fetchUserData(ctx context.Context, cfg config) ([]byte, error) {
	client := s.metadataClientFor(cfg)

	output, err := client.GetUserData(ctx, &imds.GetUserDataInput{})
	if err != nil {
		if imdsStatusCode(err) == 404 {
			return nil, nil
		}
		return nil, fmt.Errorf("read userdata from IMDS: %w", err)
	}

	return readIMDSContent(output.Content, "userdata")
}

func (s *awsState) fetchTemporaryPublicKey(ctx context.Context, cfg config) ([]byte, error) {
	body, found, err := s.fetchMetadataPath(ctx, cfg, filepath.ToSlash(filepath.Join(imdsPublicKeysMetadataPath, "0", imdsPublicKeySuffix)))
	if err != nil {
		return nil, err
	}
	if found && len(bytes.TrimSpace(body)) > 0 {
		return body, nil
	}

	indexBody, found, err := s.fetchMetadataPath(ctx, cfg, imdsPublicKeysMetadataPath+"/")
	if err != nil {
		return nil, err
	}
	if !found {
		return nil, nil
	}

	index, found := discoverPublicKeyIndex(indexBody)
	if !found {
		return nil, nil
	}

	return s.fetchMetadataPathRequired(ctx, cfg, filepath.ToSlash(filepath.Join(imdsPublicKeysMetadataPath, index, imdsPublicKeySuffix)))
}

func (s *awsState) fetchMetadataPath(ctx context.Context, cfg config, path string) ([]byte, bool, error) {
	client := s.metadataClientFor(cfg)

	output, err := client.GetMetadata(ctx, &imds.GetMetadataInput{Path: path})
	if err != nil {
		if imdsStatusCode(err) == 404 {
			return nil, false, nil
		}
		return nil, false, fmt.Errorf("read metadata path %s: %w", path, err)
	}

	body, err := readIMDSContent(output.Content, path)
	if err != nil {
		return nil, false, err
	}
	return body, true, nil
}

func (s *awsState) fetchMetadataPathRequired(ctx context.Context, cfg config, path string) ([]byte, error) {
	body, found, err := s.fetchMetadataPath(ctx, cfg, path)
	if err != nil {
		return nil, err
	}
	if !found {
		return nil, nil
	}
	return body, nil
}

func (s *awsState) prefetchMatchingBootstrap(ctx context.Context, cfg config, region string, raw []byte) (bool, error) {
	spec, matched, err := detectMonorepoBootstrapPrefetch(cfg.workDir, raw)
	if err != nil || !matched {
		return matched, err
	}

	s3Client, err := s.s3ClientFor(ctx, cfg, region)
	if err != nil {
		return true, err
	}

	if err := downloadS3ObjectToFile(ctx, s3Client, spec.S3Bucket, spec.S3Key, spec.DownloadedBinPath); err != nil {
		return true, err
	}
	if err := installBootstrapWrapper(spec.BootstrapPath, spec.DownloadedBinPath); err != nil {
		return true, err
	}

	log.Printf("prefetched RunsOn agent from s3://%s/%s to %s", spec.S3Bucket, spec.S3Key, spec.DownloadedBinPath)
	return true, nil
}

func (s *awsState) metadataClientFor(cfg config) *imds.Client {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.metadataClient != nil {
		return s.metadataClient
	}

	// The readiness loop already retries aggressively around IMDS availability,
	// so keep the per-attempt client bootstrap minimal and avoid extra SDK retries.
	s.metadataClient = imds.New(imds.Options{
		ClientEnableState:        imds.ClientEnabled,
		Endpoint:                 cfg.imdsBase,
		Retryer:                  retry.AddWithMaxAttempts(retry.NewStandard(), 1),
		DisableDefaultMaxBackoff: true,
	})
	return s.metadataClient
}

func (s *awsState) s3ClientFor(ctx context.Context, cfg config, region string) (*s3.Client, error) {
	s.mu.Lock()
	if client, ok := s.s3Clients[region]; ok {
		s.mu.Unlock()
		return client, nil
	}
	if err, ok := s.s3Errors[region]; ok {
		s.mu.Unlock()
		return nil, err
	}
	s.mu.Unlock()

	awsCfg, err := awsconfig.LoadDefaultConfig(ctx, append(metadataLoadOptions(cfg), awsconfig.WithRegion(region))...)
	if err != nil {
		err = fmt.Errorf("load AWS config for region %s: %w", region, err)
		s.mu.Lock()
		s.s3Errors[region] = err
		s.mu.Unlock()
		return nil, err
	}

	client := s3.NewFromConfig(awsCfg)
	s.mu.Lock()
	s.s3Clients[region] = client
	s.mu.Unlock()
	return client, nil
}

func metadataLoadOptions(cfg config) []func(*awsconfig.LoadOptions) error {
	options := []func(*awsconfig.LoadOptions) error{
		awsconfig.WithEC2IMDSClientEnableState(imds.ClientEnabled),
	}
	if cfg.imdsBase != "" {
		options = append(options, awsconfig.WithEC2IMDSEndpoint(cfg.imdsBase))
	}
	return options
}

func imdsStatusCode(err error) int {
	var responseErr *smithyhttp.ResponseError
	if errors.As(err, &responseErr) {
		return responseErr.HTTPStatusCode()
	}
	return 0
}

func readIMDSContent(content io.ReadCloser, label string) ([]byte, error) {
	defer content.Close()

	body, err := io.ReadAll(content)
	if err != nil {
		return nil, fmt.Errorf("read IMDS response for %s: %w", label, err)
	}
	return body, nil
}

func discoverPublicKeyIndex(body []byte) (string, bool) {
	for _, line := range strings.Split(string(bytes.TrimSpace(body)), "\n") {
		parts := strings.SplitN(strings.TrimSpace(line), "=", 2)
		if len(parts) == 2 && parts[0] != "" {
			return parts[0], true
		}
	}
	return "", false
}

func detectMonorepoBootstrapPrefetch(workDir string, raw []byte) (bootstrapPrefetchSpec, bool, error) {
	script := string(raw)
	if !strings.Contains(script, `BOOTSTRAP_BIN="/usr/local/bin/runs-on-bootstrap-$RUNS_ON_BOOTSTRAP_TAG"`) ||
		!strings.Contains(script, `AGENT_BINARY_URL="$RUNS_ON_AGENT_S3_BUCKET/agent-linux-$(uname -m)"`) ||
		!strings.Contains(script, `cat <<'EOF' > /etc/systemd/system/runs-on-bootstrap.service`) {
		return bootstrapPrefetchSpec{}, false, nil
	}

	bootstrapTag, found := extractQuotedEnvAssignment(script, "RUNS_ON_BOOTSTRAP_TAG")
	if !found {
		return bootstrapPrefetchSpec{}, false, fmt.Errorf("matched RunsOn bootstrap template missing RUNS_ON_BOOTSTRAP_TAG")
	}
	agentS3URL, found := extractQuotedEnvAssignment(script, "RUNS_ON_AGENT_S3_BUCKET")
	if !found {
		return bootstrapPrefetchSpec{}, false, fmt.Errorf("matched RunsOn bootstrap template missing RUNS_ON_AGENT_S3_BUCKET")
	}

	agentBinaryName, err := agentArtifactNameForArch(runtime.GOARCH)
	if err != nil {
		return bootstrapPrefetchSpec{}, true, err
	}

	bucket, prefix, err := parseS3URL(agentS3URL)
	if err != nil {
		return bootstrapPrefetchSpec{}, true, err
	}
	key := agentBinaryName
	if prefix != "" {
		key = strings.TrimSuffix(prefix, "/") + "/" + agentBinaryName
	}

	return bootstrapPrefetchSpec{
		BootstrapTag:      bootstrapTag,
		BootstrapPath:     filepath.Join("/usr/local/bin", "runs-on-bootstrap-"+bootstrapTag),
		AgentBinaryName:   agentBinaryName,
		S3Bucket:          bucket,
		S3Key:             key,
		DownloadedBinPath: filepath.Join(workDir, "prefetched", bootstrapTag, agentBinaryName),
	}, true, nil
}

func extractQuotedEnvAssignment(script string, key string) (string, bool) {
	prefix := key + `="`
	for _, line := range strings.Split(script, "\n") {
		line = strings.TrimSpace(line)
		if !strings.HasPrefix(line, prefix) || !strings.HasSuffix(line, `"`) {
			continue
		}
		return strings.TrimSuffix(strings.TrimPrefix(line, prefix), `"`), true
	}
	return "", false
}

func parseS3URL(raw string) (bucket string, prefix string, err error) {
	if !strings.HasPrefix(raw, "s3://") {
		return "", "", fmt.Errorf("invalid s3 url %q", raw)
	}

	path := strings.TrimPrefix(raw, "s3://")
	if path == "" {
		return "", "", fmt.Errorf("invalid s3 url %q", raw)
	}

	parts := strings.SplitN(path, "/", 2)
	if strings.TrimSpace(parts[0]) == "" {
		return "", "", fmt.Errorf("invalid s3 url %q", raw)
	}

	bucket = parts[0]
	if len(parts) == 2 {
		prefix = strings.Trim(parts[1], "/")
	}
	return bucket, prefix, nil
}

func agentArtifactNameForArch(goArch string) (string, error) {
	switch goArch {
	case "amd64":
		return "agent-linux-x86_64", nil
	case "arm64":
		return "agent-linux-aarch64", nil
	default:
		return "", fmt.Errorf("unsupported runtime arch %q", goArch)
	}
}

func downloadS3ObjectToFile(ctx context.Context, client *s3.Client, bucket string, key string, destPath string) error {
	if err := os.MkdirAll(filepath.Dir(destPath), 0o755); err != nil {
		return fmt.Errorf("create download directory for %s: %w", destPath, err)
	}

	output, err := client.GetObject(ctx, &s3.GetObjectInput{
		Bucket: aws.String(bucket),
		Key:    aws.String(key),
	})
	if err != nil {
		return fmt.Errorf("download s3://%s/%s: %w", bucket, key, err)
	}
	defer output.Body.Close()

	tempFile, err := os.CreateTemp(filepath.Dir(destPath), filepath.Base(destPath)+".tmp-*")
	if err != nil {
		return fmt.Errorf("create temp download file for %s: %w", destPath, err)
	}
	tempPath := tempFile.Name()
	defer func() { _ = os.Remove(tempPath) }()

	if _, err := io.Copy(tempFile, output.Body); err != nil {
		_ = tempFile.Close()
		return fmt.Errorf("write temp download file for %s: %w", destPath, err)
	}
	if err := tempFile.Close(); err != nil {
		return fmt.Errorf("close temp download file for %s: %w", destPath, err)
	}
	if err := os.Chmod(tempPath, 0o755); err != nil {
		return fmt.Errorf("chmod temp download file for %s: %w", destPath, err)
	}
	if err := os.Rename(tempPath, destPath); err != nil {
		return fmt.Errorf("rename temp download file for %s: %w", destPath, err)
	}
	return nil
}

func installBootstrapWrapper(path string, downloadedAgentPath string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("create bootstrap wrapper directory for %s: %w", path, err)
	}

	body := fmt.Sprintf(
		"#!/bin/bash\nset -euo pipefail\nexec %s\n",
		strconv.Quote(downloadedAgentPath),
	)
	if err := writeExecutableFile(path, []byte(body)); err != nil {
		return fmt.Errorf("install bootstrap wrapper %s: %w", path, err)
	}
	return nil
}

func writeExecutableFile(path string, body []byte) error {
	tempFile, err := os.CreateTemp(filepath.Dir(path), filepath.Base(path)+".tmp-*")
	if err != nil {
		return err
	}
	tempPath := tempFile.Name()
	defer func() { _ = os.Remove(tempPath) }()

	if _, err := tempFile.Write(body); err != nil {
		_ = tempFile.Close()
		return err
	}
	if err := tempFile.Close(); err != nil {
		return err
	}
	if err := os.Chmod(tempPath, 0o755); err != nil {
		return err
	}
	return os.Rename(tempPath, path)
}
