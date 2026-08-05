package main

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync"
	"testing"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/feature/ec2/imds"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
	ec2types "github.com/aws/aws-sdk-go-v2/service/ec2/types"
)

func TestDescribeInstanceTagsCapturesSnapshot(t *testing.T) {
	t.Parallel()

	client := &fakeEC2TagDescriber{output: &ec2.DescribeTagsOutput{Tags: []ec2types.TagDescription{
		{Key: aws.String("runs-on-role-id"), Value: aws.String("role-1")},
		{Key: aws.String("runs-on-bucket-cache"), Value: aws.String("cache")},
		{Key: nil, Value: aws.String("ignored")},
	}}}
	tags, err := describeInstanceTags(t.Context(), client, "i-123")
	if err != nil {
		t.Fatalf("describeInstanceTags() error = %v", err)
	}
	if tags["runs-on-role-id"] != "role-1" || tags["runs-on-bucket-cache"] != "cache" || len(tags) != 2 {
		t.Fatalf("describeInstanceTags() = %v", tags)
	}
	if client.input == nil || len(client.input.Filters) != 1 || len(client.input.Filters[0].Values) != 1 || client.input.Filters[0].Values[0] != "i-123" {
		t.Fatalf("DescribeTags input = %+v", client.input)
	}
}

type fakeEC2TagDescriber struct {
	input  *ec2.DescribeTagsInput
	output *ec2.DescribeTagsOutput
	err    error
}

func (f *fakeEC2TagDescriber) DescribeTags(_ context.Context, input *ec2.DescribeTagsInput, _ ...func(*ec2.Options)) (*ec2.DescribeTagsOutput, error) {
	f.input = input
	return f.output, f.err
}

func TestFetchInstanceIdentityIncludesLocalHostname(t *testing.T) {
	t.Parallel()

	state, transport := newIMDSTestState(http.StatusOK, "i-0123456789abcdef0.ec2.internal\n")
	identity, err := state.fetchInstanceIdentity(context.Background(), config{mode: launchModeFull})
	if err != nil {
		t.Fatalf("fetchInstanceIdentity returned error: %v", err)
	}
	if identity.InstanceID != "i-0123456789abcdef0" {
		t.Fatalf("unexpected instance ID %q", identity.InstanceID)
	}
	if identity.LocalHostname != "i-0123456789abcdef0.ec2.internal" {
		t.Fatalf("unexpected local hostname %q", identity.LocalHostname)
	}
	transport.assertRequestFlow(t, true)
}

func TestFetchInstanceIdentityAllowsMissingLocalHostname(t *testing.T) {
	t.Parallel()

	state, transport := newIMDSTestState(http.StatusNotFound, "")
	identity, err := state.fetchInstanceIdentity(context.Background(), config{mode: launchModeFull})
	if err != nil {
		t.Fatalf("fetchInstanceIdentity returned error: %v", err)
	}
	if identity.LocalHostname != "" {
		t.Fatalf("unexpected local hostname %q", identity.LocalHostname)
	}
	transport.assertRequestFlow(t, true)
}

func TestFetchInstanceIdentityMinimalModeSkipsLocalHostname(t *testing.T) {
	t.Parallel()

	state, transport := newIMDSTestState(http.StatusOK, "must-not-be-read.ec2.internal")
	identity, err := state.fetchInstanceIdentity(context.Background(), config{})
	if err != nil {
		t.Fatalf("fetchInstanceIdentity returned error: %v", err)
	}
	if identity.LocalHostname != "" {
		t.Fatalf("unexpected local hostname %q", identity.LocalHostname)
	}
	transport.assertRequestFlow(t, false)
}

func newIMDSTestState(localHostnameStatus int, localHostname string) (*awsState, *fakeIMDSTransport) {
	transport := &fakeIMDSTransport{
		localHostnameStatus: localHostnameStatus,
		localHostname:       localHostname,
	}
	state := newAWSState()
	state.metadataClient = imds.New(imds.Options{
		ClientEnableState: imds.ClientEnabled,
		Endpoint:          defaultIMDSEndpoint,
		HTTPClient:        &http.Client{Transport: transport},
	})
	return state, transport
}

type recordedIMDSRequest struct {
	method   string
	path     string
	token    string
	tokenTTL string
}

type fakeIMDSTransport struct {
	mu                  sync.Mutex
	requests            []recordedIMDSRequest
	localHostnameStatus int
	localHostname       string
}

func (f *fakeIMDSTransport) RoundTrip(request *http.Request) (*http.Response, error) {
	f.mu.Lock()
	f.requests = append(f.requests, recordedIMDSRequest{
		method:   request.Method,
		path:     request.URL.Path,
		token:    request.Header.Get("x-aws-ec2-metadata-token"),
		tokenTTL: request.Header.Get("x-aws-ec2-metadata-token-ttl-seconds"),
	})
	f.mu.Unlock()

	if request.Method == http.MethodPut && request.URL.Path == "/latest/api/token" {
		return fakeHTTPResponse(request, http.StatusOK, request.Header.Get("x-aws-ec2-metadata-token-ttl-seconds"), "test-token"), nil
	}
	if request.Header.Get("x-aws-ec2-metadata-token") != "test-token" {
		return fakeHTTPResponse(request, http.StatusUnauthorized, "", "missing IMDSv2 token"), nil
	}

	switch request.URL.Path {
	case "/latest/dynamic/instance-identity/document":
		return fakeHTTPResponse(request, http.StatusOK, "", `{
  "instanceId": "i-0123456789abcdef0",
  "region": "us-east-1",
  "privateIp": "10.0.0.1",
  "instanceType": "m7i.large",
  "imageId": "ami-0123456789abcdef0",
  "architecture": "x86_64",
  "pendingTime": "2026-08-03T00:00:00Z"
}`), nil
	case "/latest/meta-data/local-hostname":
		return fakeHTTPResponse(request, f.localHostnameStatus, "", f.localHostname), nil
	default:
		return fakeHTTPResponse(request, http.StatusNotFound, "", ""), nil
	}
}

func fakeHTTPResponse(request *http.Request, statusCode int, tokenTTL string, body string) *http.Response {
	header := make(http.Header)
	if tokenTTL != "" {
		header.Set("x-aws-ec2-metadata-token-ttl-seconds", tokenTTL)
	}
	return &http.Response{
		StatusCode:    statusCode,
		Status:        fmt.Sprintf("%d %s", statusCode, http.StatusText(statusCode)),
		Header:        header,
		Body:          io.NopCloser(strings.NewReader(body)),
		ContentLength: int64(len(body)),
		Request:       request,
	}
}

func (f *fakeIMDSTransport) assertRequestFlow(t *testing.T, expectLocalHostname bool) {
	t.Helper()

	f.mu.Lock()
	requests := append([]recordedIMDSRequest(nil), f.requests...)
	f.mu.Unlock()

	want := []recordedIMDSRequest{
		{method: http.MethodPut, path: "/latest/api/token", tokenTTL: "300"},
		{method: http.MethodGet, path: "/latest/dynamic/instance-identity/document", token: "test-token"},
	}
	if expectLocalHostname {
		want = append(want, recordedIMDSRequest{method: http.MethodGet, path: "/latest/meta-data/local-hostname", token: "test-token"})
	}
	if len(requests) != len(want) {
		t.Fatalf("unexpected IMDS request count %d: %+v", len(requests), requests)
	}
	for index := range want {
		if requests[index] != want[index] {
			t.Fatalf("unexpected IMDS request %d: got %+v, want %+v", index, requests[index], want[index])
		}
	}
}
