package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestFetchIMDSWithTokenReadsFullSuccessfulResponse(t *testing.T) {
	t.Parallel()

	payload := strings.Repeat("x", maxIMDSErrorBodyBytes+512)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if got := r.Header.Get("X-aws-ec2-metadata-token"); got != "token" {
			t.Fatalf("unexpected IMDS token header: %q", got)
		}
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(payload))
	}))
	defer server.Close()

	cfg := config{
		client: &http.Client{Timeout: time.Second},
	}

	body, status, err := fetchIMDSWithToken(context.Background(), cfg, "token", server.URL+"/latest/user-data")
	if err != nil {
		t.Fatalf("fetchIMDSWithToken returned error: %v", err)
	}
	if status != http.StatusOK {
		t.Fatalf("fetchIMDSWithToken returned status %d", status)
	}
	if got := string(body); got != payload {
		t.Fatalf("fetchIMDSWithToken truncated response: got %d bytes want %d", len(got), len(payload))
	}
}

func TestFetchIMDSWithTokenLimitsErrorResponseBody(t *testing.T) {
	t.Parallel()

	payload := strings.Repeat("e", maxIMDSErrorBodyBytes+512)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = w.Write([]byte(payload))
	}))
	defer server.Close()

	cfg := config{
		client: &http.Client{Timeout: time.Second},
	}

	body, status, err := fetchIMDSWithToken(context.Background(), cfg, "token", server.URL+"/latest/user-data")
	if err != nil {
		t.Fatalf("fetchIMDSWithToken returned error: %v", err)
	}
	if status != http.StatusInternalServerError {
		t.Fatalf("fetchIMDSWithToken returned status %d", status)
	}
	if got := len(body); got != maxIMDSErrorBodyBytes {
		t.Fatalf("fetchIMDSWithToken returned %d error bytes want %d", got, maxIMDSErrorBodyBytes)
	}
}

func TestResolverConfigHasEC2Resolver(t *testing.T) {
	t.Parallel()

	if !resolverConfigHasEC2Resolver([]byte("nameserver " + defaultEC2Resolver + "\n")) {
		t.Fatal("expected resolver config to detect EC2 resolver")
	}
	if resolverConfigHasEC2Resolver([]byte("nameserver 127.0.0.53\n")) {
		t.Fatal("expected non-EC2 resolver to be rejected")
	}
}

func TestEnsureResolverConfigRewritesUnexpectedResolver(t *testing.T) {
	t.Parallel()

	path := filepath.Join(t.TempDir(), "resolv.conf")
	if err := os.WriteFile(path, []byte("nameserver 10.0.0.2\n"), 0o644); err != nil {
		t.Fatalf("write test resolver config: %v", err)
	}

	if err := ensureResolverConfig(path); err != nil {
		t.Fatalf("ensureResolverConfig returned error: %v", err)
	}

	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read rewritten resolver config: %v", err)
	}

	want := "nameserver " + defaultEC2Resolver + "\noptions timeout:1 attempts:5\n"
	if got := string(raw); got != want {
		t.Fatalf("unexpected resolver config contents: %q", got)
	}
}

func TestRewriteUbuntuArchiveMirrorsSourcesList(t *testing.T) {
	t.Parallel()

	raw := []byte("deb http://us-east-1.ec2.archive.ubuntu.com/ubuntu noble main\n" +
		"deb http://security.ubuntu.com/ubuntu noble-security main\n")

	updated, changed := rewriteUbuntuArchiveMirrors(raw, "http://eu-west-3.ec2.archive.ubuntu.com/ubuntu")
	if !changed {
		t.Fatal("expected archive mirror rewrite")
	}

	want := "deb http://eu-west-3.ec2.archive.ubuntu.com/ubuntu noble main\n" +
		"deb http://security.ubuntu.com/ubuntu noble-security main\n"
	if got := string(updated); got != want {
		t.Fatalf("unexpected rewritten sources.list contents: %q", got)
	}
}

func TestRewriteUbuntuArchiveMirrorsDeb822Sources(t *testing.T) {
	t.Parallel()

	raw := []byte("Types: deb\n" +
		"URIs: http://azure.archive.ubuntu.com/ubuntu/\n" +
		"Suites: noble noble-updates noble-backports\n" +
		"Components: main restricted universe multiverse\n" +
		"Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg\n")

	updated, changed := rewriteUbuntuArchiveMirrors(raw, "http://eu-west-3.ec2.archive.ubuntu.com/ubuntu")
	if !changed {
		t.Fatal("expected archive mirror rewrite")
	}

	want := "Types: deb\n" +
		"URIs: http://eu-west-3.ec2.archive.ubuntu.com/ubuntu\n" +
		"Suites: noble noble-updates noble-backports\n" +
		"Components: main restricted universe multiverse\n" +
		"Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg\n"
	if got := string(updated); got != want {
		t.Fatalf("unexpected rewritten ubuntu.sources contents: %q", got)
	}
}

func TestFetchInstanceRegionUsesPlacementRegion(t *testing.T) {
	t.Parallel()

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == imdsPlacementRegionPath {
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte("eu-central-1"))
			return
		}
		t.Fatalf("unexpected IMDS path: %s", r.URL.Path)
	}))
	defer server.Close()

	cfg := config{
		imdsBase: server.URL,
		client:   &http.Client{Timeout: time.Second},
	}

	region, err := fetchInstanceRegion(context.Background(), cfg, "token")
	if err != nil {
		t.Fatalf("fetchInstanceRegion returned error: %v", err)
	}
	if region != "eu-central-1" {
		t.Fatalf("unexpected region %q", region)
	}
}

func TestFetchInstanceIDUsesMetadataPath(t *testing.T) {
	t.Parallel()

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != imdsInstanceIDPath {
			t.Fatalf("unexpected IMDS path: %s", r.URL.Path)
		}
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("i-1234567890abcdef0"))
	}))
	defer server.Close()

	cfg := config{
		imdsBase: server.URL,
		client:   &http.Client{Timeout: time.Second},
	}

	instanceID, err := fetchInstanceID(context.Background(), cfg, "token")
	if err != nil {
		t.Fatalf("fetchInstanceID returned error: %v", err)
	}
	if instanceID != "i-1234567890abcdef0" {
		t.Fatalf("unexpected instance id %q", instanceID)
	}
}

func TestMarkerMatchesInstance(t *testing.T) {
	t.Parallel()

	path := filepath.Join(t.TempDir(), "done-marker")
	if err := os.WriteFile(path, []byte("i-abc123\n"), 0o600); err != nil {
		t.Fatalf("write marker: %v", err)
	}

	matched, err := markerMatchesInstance(path, "i-abc123")
	if err != nil {
		t.Fatalf("markerMatchesInstance returned error: %v", err)
	}
	if !matched {
		t.Fatal("expected marker to match current instance")
	}

	matched, err = markerMatchesInstance(path, "i-def456")
	if err != nil {
		t.Fatalf("markerMatchesInstance returned error for non-match: %v", err)
	}
	if matched {
		t.Fatal("expected marker not to match different instance")
	}
}

func TestMarkerMatchesInstanceIgnoresLegacyDoneMarker(t *testing.T) {
	t.Parallel()

	path := filepath.Join(t.TempDir(), "done-marker")
	if err := os.WriteFile(path, []byte("done"), 0o600); err != nil {
		t.Fatalf("write legacy marker: %v", err)
	}

	matched, err := markerMatchesInstance(path, "i-abc123")
	if err != nil {
		t.Fatalf("markerMatchesInstance returned error: %v", err)
	}
	if matched {
		t.Fatal("expected legacy marker to be ignored")
	}
}

func TestMarkDoneWritesInstanceID(t *testing.T) {
	t.Parallel()

	path := filepath.Join(t.TempDir(), "done-marker")
	if err := markDone(path, "i-abc123"); err != nil {
		t.Fatalf("markDone returned error: %v", err)
	}

	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read marker: %v", err)
	}
	if got := string(raw); got != "i-abc123\n" {
		t.Fatalf("unexpected marker contents %q", got)
	}
}
