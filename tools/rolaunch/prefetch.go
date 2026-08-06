package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"math/rand/v2"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	aws "github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/smithy-go/transport/http"
)

const (
	descriptorPrefix   = "# runs-on-rolaunch-descriptor:"
	descriptorVersion  = 1
	instanceConfigName = "instance-config.json"
	runnerConfigName   = "runner-config.json"
)

var safeDescriptorToken = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._:/+=@-]{0,254}$`)
var safeS3Bucket = regexp.MustCompile(`^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$`)

type bootstrapDescriptor struct {
	Version     int             `json:"version"`
	CacheBucket string          `json:"cacheBucket"`
	RoleID      string          `json:"roleId"`
	Agent       descriptorAgent `json:"agent"`
	Handoff     descriptorPaths `json:"handoff"`
}

type descriptorAgent struct {
	Bucket           string `json:"bucket"`
	KeyPrefix        string `json:"keyPrefix"`
	InstallDirectory string `json:"installDirectory"`
	BootstrapPath    string `json:"bootstrapPath"`
}

type descriptorPaths struct {
	Directory    string `json:"directory"`
	AckDirectory string `json:"ackDirectory"`
}

type prefetchReceipt struct {
	ReceiptVersion    int               `json:"receiptVersion"`
	DescriptorVersion int               `json:"descriptorVersion"`
	ObjectKey         string            `json:"objectKey"`
	ETag              string            `json:"etag,omitempty"`
	VersionID         string            `json:"versionId,omitempty"`
	LastModified      *time.Time        `json:"lastModified,omitempty"`
	InstanceID        string            `json:"instanceId"`
	Region            string            `json:"region"`
	ImageID           string            `json:"imageId,omitempty"`
	RoleID            string            `json:"roleId"`
	AssignmentID      string            `json:"assignmentId,omitempty"`
	ObjectMetadata    map[string]string `json:"objectMetadata,omitempty"`
	PublishedAt       time.Time         `json:"publishedAt"`
}

type fetchedObject struct {
	body         []byte
	etag         string
	versionID    string
	lastModified *time.Time
	metadata     map[string]string
}

type configPollSpec struct {
	name              string
	key               string
	path              string
	receiptPath       string
	ackPath           string
	requireAssignment bool
}

var s3ClientForPoll = func(ctx context.Context, state *awsState, cfg config, region string) (s3ObjectGetter, error) {
	return state.retriableS3Client(ctx, cfg, region)
}

type pollSummary struct {
	attempts  int
	notFound  int
	transient int
	forbidden int
}

func parseBootstrapDescriptor(raw []byte) (bootstrapDescriptor, bool, error) {
	var encoded string
	for _, line := range strings.Split(string(raw), "\n") {
		trimmed := strings.TrimSpace(line)
		if !strings.HasPrefix(trimmed, descriptorPrefix) {
			continue
		}
		if encoded != "" {
			return bootstrapDescriptor{}, true, errors.New("multiple rolaunch descriptors in user data")
		}
		encoded = strings.TrimSpace(strings.TrimPrefix(trimmed, descriptorPrefix))
	}
	if encoded == "" {
		return bootstrapDescriptor{}, false, nil
	}

	decoder := json.NewDecoder(strings.NewReader(encoded))
	decoder.DisallowUnknownFields()
	var descriptor bootstrapDescriptor
	if err := decoder.Decode(&descriptor); err != nil {
		return bootstrapDescriptor{}, true, fmt.Errorf("decode rolaunch descriptor: %w", err)
	}
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		return bootstrapDescriptor{}, true, errors.New("decode rolaunch descriptor: trailing JSON content")
	}
	if err := validateBootstrapDescriptor(descriptor); err != nil {
		return bootstrapDescriptor{}, true, err
	}
	return descriptor, true, nil
}

func validateBootstrapDescriptor(descriptor bootstrapDescriptor) error {
	if descriptor.Version != descriptorVersion {
		return fmt.Errorf("unsupported rolaunch descriptor version %d", descriptor.Version)
	}
	for label, value := range map[string]string{"cache bucket": descriptor.CacheBucket, "agent bucket": descriptor.Agent.Bucket} {
		if !safeS3Bucket.MatchString(value) || strings.Contains(value, "..") {
			return fmt.Errorf("invalid descriptor %s %q", label, value)
		}
	}
	if !safeDescriptorToken.MatchString(descriptor.RoleID) || strings.Contains(descriptor.RoleID, "..") {
		return fmt.Errorf("invalid descriptor role id %q", descriptor.RoleID)
	}
	if descriptor.Agent.KeyPrefix == "" || strings.HasPrefix(descriptor.Agent.KeyPrefix, "/") || pathEscapes(descriptor.Agent.KeyPrefix) {
		return fmt.Errorf("invalid descriptor agent key prefix %q", descriptor.Agent.KeyPrefix)
	}
	for label, value := range map[string]string{
		"agent install directory": descriptor.Agent.InstallDirectory,
		"bootstrap path":          descriptor.Agent.BootstrapPath,
		"handoff directory":       descriptor.Handoff.Directory,
		"ack directory":           descriptor.Handoff.AckDirectory,
	} {
		if !filepath.IsAbs(value) || filepath.Clean(value) != value {
			return fmt.Errorf("invalid descriptor %s %q", label, value)
		}
	}
	if !strings.HasPrefix(descriptor.Agent.InstallDirectory, defaultWorkDir+string(os.PathSeparator)) {
		return fmt.Errorf("agent install directory must be below %s", defaultWorkDir)
	}
	if !strings.HasPrefix(descriptor.Agent.BootstrapPath, "/usr/local/bin/runs-on-bootstrap-") {
		return errors.New("bootstrap path must name a versioned RunsOn bootstrap under /usr/local/bin")
	}
	if descriptor.Handoff.Directory != filepath.Join(defaultWorkDir, "prefetch") {
		return fmt.Errorf("handoff directory must be %s", filepath.Join(defaultWorkDir, "prefetch"))
	}
	if descriptor.Handoff.AckDirectory != filepath.Join(descriptor.Handoff.Directory, "ack") {
		return errors.New("ack directory must be the handoff ack subdirectory")
	}
	return nil
}

func pathEscapes(value string) bool {
	for _, segment := range strings.Split(filepath.ToSlash(value), "/") {
		if segment == ".." {
			return true
		}
	}
	return false
}

func descriptorAgentSpec(descriptor bootstrapDescriptor) (bootstrapPrefetchSpec, error) {
	artifact, err := agentArtifactNameForArch(runtimeGOARCH())
	if err != nil {
		return bootstrapPrefetchSpec{}, err
	}
	return bootstrapPrefetchSpec{
		BootstrapPath:     descriptor.Agent.BootstrapPath,
		AgentBinaryName:   artifact,
		S3Bucket:          descriptor.Agent.Bucket,
		S3Key:             strings.TrimSuffix(descriptor.Agent.KeyPrefix, "/") + "/" + artifact,
		DownloadedBinPath: filepath.Join(descriptor.Agent.InstallDirectory, artifact),
	}, nil
}

var runtimeGOARCH = currentGOARCH

func configPollSpecs(descriptor bootstrapDescriptor, identity instanceIdentity) []configPollSpec {
	baseKey := fmt.Sprintf("runners/%s:%s", descriptor.RoleID, identity.InstanceID)
	return []configPollSpec{
		{
			name:        "instance-config",
			key:         baseKey + "/instance-config.json",
			path:        filepath.Join(descriptor.Handoff.Directory, instanceConfigName),
			receiptPath: filepath.Join(descriptor.Handoff.Directory, instanceConfigName+".receipt.json"),
			ackPath:     filepath.Join(descriptor.Handoff.AckDirectory, instanceConfigName+".ack"),
		},
		{
			name:              "runner-config",
			key:               baseKey + "/runner-config.json",
			path:              filepath.Join(descriptor.Handoff.Directory, runnerConfigName),
			receiptPath:       filepath.Join(descriptor.Handoff.Directory, runnerConfigName+".receipt.json"),
			ackPath:           filepath.Join(descriptor.Handoff.AckDirectory, runnerConfigName+".ack"),
			requireAssignment: true,
		},
	}
}

func prefetchConfigObjects(ctx context.Context, state *awsState, cfg config, identity instanceIdentity, descriptor bootstrapDescriptor) error {
	if err := secureDirectory(descriptor.Handoff.Directory); err != nil {
		return err
	}
	if err := secureDirectory(descriptor.Handoff.AckDirectory); err != nil {
		return err
	}

	results := make(chan error, 2)
	for _, spec := range configPollSpecs(descriptor, identity) {
		spec := spec
		go func() {
			results <- pollConfigObject(ctx, state, cfg, identity, descriptor, spec)
		}()
	}
	var firstErr error
	for range 2 {
		if err := <-results; err != nil && firstErr == nil {
			firstErr = err
		}
	}
	return firstErr
}

func pollConfigObject(ctx context.Context, state *awsState, cfg config, identity instanceIdentity, descriptor bootstrapDescriptor, spec configPollSpec) error {
	summary := pollSummary{}
	marker("rolaunch.config-poll-started", identity.InstanceID, spec.name)
	for {
		if ctx.Err() != nil {
			log.Printf("config prefetch %s stopped at startup deadline (attempts=%d not_found=%d transient=%d forbidden=%d)", spec.name, summary.attempts, summary.notFound, summary.transient, summary.forbidden)
			return nil
		}

		summary.attempts++
		client, err := s3ClientForPoll(ctx, state, cfg, identity.Region)
		if err != nil {
			summary.transient++
			if !waitForPollRetry(ctx, summary.attempts) {
				continue
			}
			continue
		}
		object, err := fetchS3Object(ctx, client, descriptor.CacheBucket, spec.key)
		if err != nil {
			status := s3StatusCode(err)
			switch {
			case status == 404:
				summary.notFound++
			case status == 403:
				summary.forbidden++
				if summary.forbidden >= 3 {
					return fmt.Errorf("persistent 403 polling s3://%s/%s after %d attempts", descriptor.CacheBucket, spec.key, summary.attempts)
				}
			case status == 0 || status >= 500:
				summary.transient++
			default:
				return fmt.Errorf("non-retriable error polling s3://%s/%s: %w", descriptor.CacheBucket, spec.key, err)
			}
			waitForPollRetry(ctx, summary.attempts)
			continue
		}

		assignmentID, err := validateConfigObject(object, spec)
		if err != nil {
			return fmt.Errorf("invalid %s from s3://%s/%s: %w", spec.name, descriptor.CacheBucket, spec.key, err)
		}
		receipt := prefetchReceipt{
			ReceiptVersion:    1,
			DescriptorVersion: descriptor.Version,
			ObjectKey:         spec.key,
			ETag:              object.etag,
			VersionID:         object.versionID,
			LastModified:      object.lastModified,
			InstanceID:        identity.InstanceID,
			Region:            identity.Region,
			ImageID:           identity.ImageID,
			RoleID:            descriptor.RoleID,
			AssignmentID:      assignmentID,
			ObjectMetadata:    object.metadata,
			PublishedAt:       time.Now().UTC(),
		}
		if err := publishConfigAndReceipt(spec, object.body, receipt); err != nil {
			return err
		}
		marker("rolaunch.config-published", identity.InstanceID, spec.name)
		log.Printf("config prefetch %s published (attempts=%d not_found=%d transient=%d forbidden=%d)", spec.name, summary.attempts, summary.notFound, summary.transient, summary.forbidden)

		for !acknowledgesReceipt(spec.ackPath, receipt) {
			if !waitForPollRetry(ctx, summary.attempts) && ctx.Err() != nil {
				return nil
			}
		}
		marker("rolaunch.config-acknowledged", identity.InstanceID, spec.name)
		return nil
	}
}

func fetchS3Object(ctx context.Context, client s3ObjectGetter, bucket string, key string) (fetchedObject, error) {
	output, err := client.GetObject(ctx, &s3.GetObjectInput{Bucket: aws.String(bucket), Key: aws.String(key)})
	if err != nil {
		return fetchedObject{}, err
	}
	defer output.Body.Close()
	body, err := io.ReadAll(io.LimitReader(output.Body, 16<<20))
	if err != nil {
		return fetchedObject{}, fmt.Errorf("read s3://%s/%s: %w", bucket, key, err)
	}
	if len(body) == 16<<20 {
		return fetchedObject{}, fmt.Errorf("s3://%s/%s exceeds 16 MiB", bucket, key)
	}
	return fetchedObject{
		body:         body,
		etag:         aws.ToString(output.ETag),
		versionID:    aws.ToString(output.VersionId),
		lastModified: output.LastModified,
		metadata:     output.Metadata,
	}, nil
}

func validateConfigObject(object fetchedObject, spec configPollSpec) (string, error) {
	var decoded map[string]json.RawMessage
	if err := json.Unmarshal(object.body, &decoded); err != nil {
		return "", err
	}
	if decoded == nil {
		return "", errors.New("JSON object is null")
	}
	if !spec.requireAssignment {
		return strings.TrimSpace(object.metadata["assignment-id"]), nil
	}
	var assignmentID string
	if err := json.Unmarshal(decoded["assignmentId"], &assignmentID); err != nil || strings.TrimSpace(assignmentID) == "" {
		return "", errors.New("runner config has no valid assignmentId")
	}
	assignmentID = strings.TrimSpace(assignmentID)
	metadataAssignment := strings.TrimSpace(object.metadata["assignment-id"])
	if metadataAssignment == "" {
		return "", errors.New("runner config object has no assignment-id metadata")
	}
	if metadataAssignment != assignmentID {
		return "", fmt.Errorf("assignment mismatch: JSON=%q metadata=%q", assignmentID, metadataAssignment)
	}
	return assignmentID, nil
}

func publishConfigAndReceipt(spec configPollSpec, body []byte, receipt prefetchReceipt) error {
	if err := writeAtomicFile(spec.path, body, 0o600); err != nil {
		return fmt.Errorf("publish %s: %w", spec.name, err)
	}
	receiptBody, err := json.Marshal(receipt)
	if err != nil {
		return fmt.Errorf("marshal %s receipt: %w", spec.name, err)
	}
	if err := writeAtomicFile(spec.receiptPath, receiptBody, 0o600); err != nil {
		return fmt.Errorf("publish %s receipt: %w", spec.name, err)
	}
	return nil
}

func secureDirectory(path string) error {
	if err := os.MkdirAll(path, 0o700); err != nil {
		return fmt.Errorf("create secure directory %s: %w", path, err)
	}
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("secure directory path is not a directory: %s", path)
	}
	return os.Chmod(path, 0o700)
}

func writeAtomicFile(path string, body []byte, mode os.FileMode) error {
	dir := filepath.Dir(path)
	if strings.HasPrefix(path, defaultWorkDir+string(os.PathSeparator)) {
		if err := secureDirectory(dir); err != nil {
			return err
		}
	} else if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	if info, err := os.Lstat(path); err == nil && (!info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0) {
		return fmt.Errorf("refusing to replace non-regular file %s", path)
	} else if err != nil && !os.IsNotExist(err) {
		return err
	}
	tempFile, err := os.CreateTemp(dir, ".rolaunch-tmp-*")
	if err != nil {
		return err
	}
	tempPath := tempFile.Name()
	defer os.Remove(tempPath)
	if err := tempFile.Chmod(mode); err != nil {
		tempFile.Close()
		return err
	}
	if _, err := tempFile.Write(body); err != nil {
		tempFile.Close()
		return err
	}
	if err := tempFile.Sync(); err != nil {
		tempFile.Close()
		return err
	}
	if err := tempFile.Close(); err != nil {
		return err
	}
	if err := os.Rename(tempPath, path); err != nil {
		return err
	}
	dirFile, err := os.Open(dir)
	if err != nil {
		return err
	}
	defer dirFile.Close()
	return dirFile.Sync()
}

func waitForPollRetry(ctx context.Context, attempt int) bool {
	maximum := 750 * time.Millisecond
	base := 35 * time.Millisecond * time.Duration(1<<min(attempt, 4))
	if base > maximum {
		base = maximum
	}
	delay := base/2 + time.Duration(rand.Int64N(int64(base/2)+1))
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-timer.C:
		return true
	}
}

func s3StatusCode(err error) int {
	var responseErr *http.ResponseError
	if errors.As(err, &responseErr) {
		return responseErr.HTTPStatusCode()
	}
	return 0
}

var processStarted = time.Now()

func marker(name string, instanceID string, object string) {
	log.Printf("marker=%s utc=%s monotonic_ms=%d instance_id=%s object=%s", name, time.Now().UTC().Format(time.RFC3339Nano), time.Since(processStarted).Milliseconds(), instanceID, object)
}
