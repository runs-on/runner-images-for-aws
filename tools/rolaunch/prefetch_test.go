package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	aws "github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	smithyhttp "github.com/aws/smithy-go/transport/http"
)

func validDescriptorLine() []byte {
	return []byte(`#!/bin/bash
# runs-on-rolaunch-descriptor: {"version":1,"cacheBucket":"cache-bucket","roleId":"role-123","agent":{"bucket":"agent-bucket","keyPrefix":"agents/v2.12.3","installDirectory":"/var/lib/rolaunch/agent","bootstrapPath":"/usr/local/bin/runs-on-bootstrap-v0.1.12"},"handoff":{"directory":"/var/lib/rolaunch/prefetch","ackDirectory":"/var/lib/rolaunch/prefetch/ack"}}
`)
}

func TestParseBootstrapDescriptor(t *testing.T) {
	t.Parallel()
	descriptor, matched, err := parseBootstrapDescriptor(validDescriptorLine())
	if err != nil {
		t.Fatal(err)
	}
	if !matched || descriptor.Version != 1 || descriptor.RoleID != "role-123" {
		t.Fatalf("unexpected descriptor: matched=%v descriptor=%+v", matched, descriptor)
	}
	spec, err := descriptorAgentSpec(descriptor)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(spec.AgentBinaryName, "agent-linux-") {
		t.Fatalf("unexpected artifact %q", spec.AgentBinaryName)
	}
	if spec.S3Key != "agents/v2.12.3/"+spec.AgentBinaryName {
		t.Fatalf("unexpected key %q", spec.S3Key)
	}
}

func TestParseBootstrapDescriptorLeavesOrdinaryUserDataInactive(t *testing.T) {
	t.Parallel()
	if _, matched, err := parseBootstrapDescriptor([]byte("#!/bin/sh\necho safe\n")); err != nil || matched {
		t.Fatalf("ordinary user data matched descriptor: matched=%v err=%v", matched, err)
	}
}

func TestParseBootstrapDescriptorRejectsInvalidContract(t *testing.T) {
	t.Parallel()
	cases := [][]byte{
		[]byte("# runs-on-rolaunch-descriptor: {not-json}\n"),
		[]byte("# runs-on-rolaunch-descriptor: {\"version\":2}\n"),
		append(validDescriptorLine(), validDescriptorLine()...),
		[]byte(strings.Replace(string(validDescriptorLine()), `"roleId":"role-123"`, `"roleId":"../role"`, 1)),
	}
	for _, raw := range cases {
		if _, matched, err := parseBootstrapDescriptor(raw); !matched || err == nil {
			t.Fatalf("invalid descriptor accepted: matched=%v err=%v raw=%s", matched, err, raw)
		}
	}
}

func TestValidateRunnerConfigRequiresMatchingAssignment(t *testing.T) {
	t.Parallel()
	spec := configPollSpec{requireAssignment: true}
	valid := fetchedObject{
		body:     []byte(`{"assignmentId":"assignment-1","runnerJitConfig":"secret"}`),
		metadata: map[string]string{"assignment-id": "assignment-1"},
	}
	if got, err := validateConfigObject(valid, spec); err != nil || got != "assignment-1" {
		t.Fatalf("valid runner config rejected: assignment=%q err=%v", got, err)
	}
	valid.metadata["assignment-id"] = "assignment-old"
	if _, err := validateConfigObject(valid, spec); err == nil {
		t.Fatal("mismatched assignment metadata accepted")
	}
}

func TestPublishConfigAndReceiptIsPrivateAndAtomic(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	spec := configPollSpec{
		name:        "instance-config",
		path:        filepath.Join(dir, "instance-config.json"),
		receiptPath: filepath.Join(dir, "instance-config.json.receipt.json"),
	}
	receipt := prefetchReceipt{ReceiptVersion: 1, DescriptorVersion: 1, ObjectKey: "key", InstanceID: "i-1", RoleID: "role-1"}
	if err := publishConfigAndReceipt(spec, []byte(`{"stackName":"test"}`), receipt); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{spec.path, spec.receiptPath} {
		info, err := os.Lstat(path)
		if err != nil {
			t.Fatal(err)
		}
		if !info.Mode().IsRegular() || info.Mode().Perm() != 0o600 {
			t.Fatalf("unexpected mode for %s: %v", path, info.Mode())
		}
	}
}

func TestPollConfigObjectRetries404PublishesReceiptAndStopsOnAck(t *testing.T) {
	dir := t.TempDir()
	spec := configPollSpec{
		name:              "runner-config",
		key:               "runners/role-1:i-1/runner-config.json",
		path:              filepath.Join(dir, "runner-config.json"),
		receiptPath:       filepath.Join(dir, "runner-config.json.receipt.json"),
		ackPath:           filepath.Join(dir, "ack", "runner-config.json.ack"),
		requireAssignment: true,
	}
	client := &sequenceS3Getter{responses: []s3SequenceResponse{
		{status: 404},
		{body: `{"assignmentId":"assignment-1"}`, metadata: map[string]string{"assignment-id": "assignment-1"}, etag: `"etag-1"`, versionID: "version-1"},
	}}
	oldFactory := s3ClientForPoll
	s3ClientForPoll = func(context.Context, *awsState, config, string) (s3ObjectGetter, error) { return client, nil }
	t.Cleanup(func() { s3ClientForPoll = oldFactory })

	go func() {
		for {
			if _, err := os.Stat(spec.receiptPath); err == nil {
				ackBody, _ := json.Marshal(prefetchAcknowledgment{ReceiptVersion: 1, ObjectKey: spec.key, InstanceID: "i-1", AssignmentID: "assignment-1"})
				_ = writeAtomicFile(spec.ackPath, ackBody, 0o600)
				return
			}
			time.Sleep(5 * time.Millisecond)
		}
	}()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	descriptor := bootstrapDescriptor{Version: 1, CacheBucket: "cache", RoleID: "role-1"}
	identity := instanceIdentity{InstanceID: "i-1", Region: "us-east-1", ImageID: "ami-1"}
	if err := pollConfigObject(ctx, newAWSState(), config{}, identity, descriptor, spec); err != nil {
		t.Fatal(err)
	}
	if client.callCount() != 2 {
		t.Fatalf("unexpected S3 attempt count %d", client.callCount())
	}
	receiptBody, err := os.ReadFile(spec.receiptPath)
	if err != nil {
		t.Fatal(err)
	}
	text := string(receiptBody)
	for _, want := range []string{`"objectKey":"runners/role-1:i-1/runner-config.json"`, `"etag":"\"etag-1\""`, `"assignmentId":"assignment-1"`, `"instanceId":"i-1"`} {
		if !strings.Contains(text, want) {
			t.Fatalf("receipt missing %s: %s", want, text)
		}
	}
}

func TestPollConfigObjectFailsClearlyOnPersistent403(t *testing.T) {
	client := &sequenceS3Getter{responses: []s3SequenceResponse{{status: 403}, {status: 403}, {status: 403}}}
	oldFactory := s3ClientForPoll
	s3ClientForPoll = func(context.Context, *awsState, config, string) (s3ObjectGetter, error) { return client, nil }
	t.Cleanup(func() { s3ClientForPoll = oldFactory })
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	err := pollConfigObject(ctx, newAWSState(), config{}, instanceIdentity{InstanceID: "i-1"}, bootstrapDescriptor{CacheBucket: "cache"}, configPollSpec{name: "runner", key: "key"})
	if err == nil || !strings.Contains(err.Error(), "persistent 403") {
		t.Fatalf("unexpected error: %v", err)
	}
}

type s3SequenceResponse struct {
	status    int
	body      string
	metadata  map[string]string
	etag      string
	versionID string
}

type sequenceS3Getter struct {
	mu        sync.Mutex
	responses []s3SequenceResponse
	calls     int
}

func (f *sequenceS3Getter) GetObject(_ context.Context, _ *s3.GetObjectInput, _ ...func(*s3.Options)) (*s3.GetObjectOutput, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	index := f.calls
	f.calls++
	if index >= len(f.responses) {
		return nil, fmt.Errorf("unexpected S3 call %d", index+1)
	}
	response := f.responses[index]
	if response.status != 0 {
		return nil, &smithyhttp.ResponseError{
			Response: &smithyhttp.Response{Response: &http.Response{StatusCode: response.status}},
			Err:      fmt.Errorf("status %d", response.status),
		}
	}
	now := time.Now().UTC()
	return &s3.GetObjectOutput{
		Body:         io.NopCloser(strings.NewReader(response.body)),
		ETag:         aws.String(response.etag),
		VersionId:    aws.String(response.versionID),
		LastModified: &now,
		Metadata:     response.metadata,
	}, nil
}

func (f *sequenceS3Getter) callCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.calls
}
