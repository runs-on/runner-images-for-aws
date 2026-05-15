package main

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	aws "github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	smithyhttp "github.com/aws/smithy-go/transport/http"
)

func TestDetectMonorepoBootstrapPrefetch(t *testing.T) {
	t.Parallel()

	workDir := t.TempDir()
	raw := []byte(`#!/bin/bash -ex
cat <<EOF > /etc/runs-on/bootstrap.env
RUNS_ON_BOOTSTRAP_TAG="v0.1.12"
RUNS_ON_AGENT_S3_BUCKET="s3://cache-bucket/agents/v2.12.3"
EOF

cat <<'EOF' > /usr/local/bin/runs-on-bootstrap.sh
#!/bin/bash
BOOTSTRAP_BIN="/usr/local/bin/runs-on-bootstrap-$RUNS_ON_BOOTSTRAP_TAG"
AGENT_BINARY_URL="$RUNS_ON_AGENT_S3_BUCKET/agent-linux-$(uname -m)"
EOF

cat <<'EOF' > /etc/systemd/system/runs-on-bootstrap.service
[Service]
ExecStart=/bin/bash -lc '/usr/local/bin/runs-on-bootstrap.sh'
EOF
`)

	spec, matched, err := detectMonorepoBootstrapPrefetch(workDir, raw)
	if err != nil {
		t.Fatalf("detectMonorepoBootstrapPrefetch returned error: %v", err)
	}
	if !matched {
		t.Fatal("expected bootstrap template to match")
	}
	if spec.BootstrapTag != "v0.1.12" {
		t.Fatalf("unexpected bootstrap tag %q", spec.BootstrapTag)
	}
	if spec.S3Bucket != "cache-bucket" {
		t.Fatalf("unexpected s3 bucket %q", spec.S3Bucket)
	}

	wantBinaryName, err := agentArtifactNameForArch(runtime.GOARCH)
	if err != nil {
		t.Fatalf("agentArtifactNameForArch returned error: %v", err)
	}
	if spec.AgentBinaryName != wantBinaryName {
		t.Fatalf("unexpected agent binary name %q want %q", spec.AgentBinaryName, wantBinaryName)
	}
	if spec.S3Key != "agents/v2.12.3/"+wantBinaryName {
		t.Fatalf("unexpected s3 key %q", spec.S3Key)
	}
	if spec.BootstrapPath != "/usr/local/bin/runs-on-bootstrap-v0.1.12" {
		t.Fatalf("unexpected bootstrap path %q", spec.BootstrapPath)
	}
	if want := filepath.Join(workDir, "prefetched", "v0.1.12", wantBinaryName); spec.DownloadedBinPath != want {
		t.Fatalf("unexpected download path %q want %q", spec.DownloadedBinPath, want)
	}
}

func TestDetectMonorepoBootstrapPrefetchRejectsUnrelatedUserData(t *testing.T) {
	t.Parallel()

	spec, matched, err := detectMonorepoBootstrapPrefetch(t.TempDir(), []byte("#!/bin/sh\necho hello\n"))
	if err != nil {
		t.Fatalf("detectMonorepoBootstrapPrefetch returned error: %v", err)
	}
	if matched {
		t.Fatalf("expected no match, got %+v", spec)
	}
}

func TestParseS3URL(t *testing.T) {
	t.Parallel()

	bucket, prefix, err := parseS3URL("s3://runs-on-dev/agents/v2.12.3")
	if err != nil {
		t.Fatalf("parseS3URL returned error: %v", err)
	}
	if bucket != "runs-on-dev" || prefix != "agents/v2.12.3" {
		t.Fatalf("unexpected parse result bucket=%q prefix=%q", bucket, prefix)
	}
}

func TestExtractBootstrapEnvValues(t *testing.T) {
	t.Parallel()

	raw := []byte(`#!/bin/bash -ex
cat <<EOF > /etc/runs-on/bootstrap.env
RUNS_ON_S3_BUCKET_CACHE="cache-bucket"
RUNS_ON_ROLE_ID="role-123"
EOF
`)

	values, ok := extractBootstrapEnvValues(raw)
	if !ok {
		t.Fatal("expected bootstrap env values to be extracted")
	}
	if values.S3BucketCache != "cache-bucket" {
		t.Fatalf("unexpected bucket cache %q", values.S3BucketCache)
	}
	if values.RoleID != "role-123" {
		t.Fatalf("unexpected role id %q", values.RoleID)
	}
}

func TestPrefetchAgentConfigFilesWithClientBestEffort(t *testing.T) {
	t.Parallel()

	raw := []byte(`#!/bin/bash -ex
cat <<EOF > /etc/runs-on/bootstrap.env
RUNS_ON_S3_BUCKET_CACHE="cache-bucket"
RUNS_ON_ROLE_ID="role-123"
EOF
`)
	identity := instanceIdentity{InstanceID: "i-123", Region: "eu-west-3"}
	instancePath := filepath.Join(t.TempDir(), "instance-config.json")
	runnerPath := filepath.Join(t.TempDir(), "config.json")
	client := &fakeS3ObjectGetter{
		objects: map[string]string{
			"runners/role-123:i-123/instance-config.json": `{"stackName":"runs-on"}`,
		},
		notFound: map[string]bool{
			"runners/role-123:i-123/runner-config.json": true,
		},
	}

	if err := prefetchAgentConfigFilesWithClient(context.Background(), client, identity, raw, instancePath, runnerPath); err != nil {
		t.Fatalf("prefetchAgentConfigFilesWithClient returned error: %v", err)
	}

	if got := client.requests; len(got) != 2 {
		t.Fatalf("unexpected request count %d: %v", len(got), got)
	}
	if client.requests[0] != "runners/role-123:i-123/instance-config.json" {
		t.Fatalf("unexpected first request %q", client.requests[0])
	}
	if client.requests[1] != "runners/role-123:i-123/runner-config.json" {
		t.Fatalf("unexpected second request %q", client.requests[1])
	}

	rawInstance, err := os.ReadFile(instancePath)
	if err != nil {
		t.Fatalf("read instance config: %v", err)
	}
	if got := string(rawInstance); got != `{"stackName":"runs-on"}` {
		t.Fatalf("unexpected instance config contents %q", got)
	}
	if _, err := os.Stat(runnerPath); !os.IsNotExist(err) {
		t.Fatalf("expected runner config to remain absent, stat err=%v", err)
	}
}

type fakeS3ObjectGetter struct {
	objects  map[string]string
	notFound map[string]bool
	requests []string
}

func (f *fakeS3ObjectGetter) GetObject(_ context.Context, input *s3.GetObjectInput, _ ...func(*s3.Options)) (*s3.GetObjectOutput, error) {
	if input == nil || input.Key == nil {
		return nil, fmt.Errorf("missing key")
	}

	key := aws.ToString(input.Key)
	f.requests = append(f.requests, key)
	if f.notFound[key] {
		return nil, &smithyhttp.ResponseError{
			Response: &smithyhttp.Response{Response: &http.Response{StatusCode: 404}},
			Err:      fmt.Errorf("not found"),
		}
	}

	body, ok := f.objects[key]
	if !ok {
		return nil, fmt.Errorf("unexpected key %s", key)
	}
	return &s3.GetObjectOutput{Body: io.NopCloser(strings.NewReader(body))}, nil
}

func TestInstallBootstrapWrapper(t *testing.T) {
	t.Parallel()

	root := t.TempDir()
	wrapperPath := filepath.Join(root, "usr", "local", "bin", "runs-on-bootstrap-v0.1.12")
	agentPath := filepath.Join(root, "var", "lib", "rolaunch", "prefetched", "agent-linux-x86_64")

	if err := installBootstrapWrapper(wrapperPath, agentPath); err != nil {
		t.Fatalf("installBootstrapWrapper returned error: %v", err)
	}

	raw, err := os.ReadFile(wrapperPath)
	if err != nil {
		t.Fatalf("read wrapper: %v", err)
	}
	text := string(raw)
	if !strings.Contains(text, `exec "`+agentPath+`"`) {
		t.Fatalf("wrapper does not exec downloaded agent: %q", text)
	}

	info, err := os.Stat(wrapperPath)
	if err != nil {
		t.Fatalf("stat wrapper: %v", err)
	}
	if info.Mode().Perm() != 0o755 {
		t.Fatalf("unexpected wrapper perms %o", info.Mode().Perm())
	}
}
