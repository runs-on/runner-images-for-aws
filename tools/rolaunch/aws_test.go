package main

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestDetectMonorepoBootstrapPrefetch(t *testing.T) {
	t.Parallel()

	workDir := t.TempDir()
	raw := []byte(`#!/bin/bash -ex
cat <<EOF > /etc/runs-on/bootstrap.env
RUNS_ON_BOOTSTRAP_TAG="v0.1.12"
RUNS_ON_AGENT_S3_BUCKET="s3://config-bucket/agents/v2.12.3"
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
	if spec.S3Bucket != "config-bucket" {
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
