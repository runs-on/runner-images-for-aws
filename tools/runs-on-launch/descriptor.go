package main

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"regexp"
	"strings"
)

const descriptorPrefix = "# runs-on-launch:v1:"

var (
	bootstrapVersionPattern = regexp.MustCompile(`^v[0-9]+\.[0-9]+\.[0-9]+$`)
	allowedEnvironment      = map[string]struct{}{
		"AWS_REGION":                     {},
		"RUNS_ON_ECR_CACHE":              {},
		"RUNS_ON_ECR_PULL_THROUGH_CACHE": {},
		"RUNS_ON_ECR_PULL_THROUGH_CACHE_DOCKER_HUB_MIRROR": {},
		"RUNS_ON_EFS_ID":             {},
		"RUNS_ON_LOG_GROUP_NAME":     {},
		"RUNS_ON_RUNNER_MAX_RUNTIME": {},
		"RUNS_ON_S3_BUCKET_CACHE":    {},
	}
)

type launchDescriptor struct {
	Version          int               `json:"version"`
	BootstrapVersion string            `json:"bootstrap_version"`
	AgentS3URL       string            `json:"agent_s3_url"`
	Debug            bool              `json:"debug"`
	PostExec         string            `json:"post_exec"`
	Environment      map[string]string `json:"environment"`
}

func parseLaunchDescriptor(userData []byte) (launchDescriptor, error) {
	for _, line := range strings.Split(string(userData), "\n") {
		line = strings.TrimSpace(line)
		if !strings.HasPrefix(line, descriptorPrefix) {
			continue
		}

		encoded := strings.TrimSpace(strings.TrimPrefix(line, descriptorPrefix))
		raw, err := base64.RawStdEncoding.DecodeString(encoded)
		if err != nil {
			raw, err = base64.StdEncoding.DecodeString(encoded)
		}
		if err != nil {
			return launchDescriptor{}, fmt.Errorf("decode runs-on-launch descriptor: %w", err)
		}

		var descriptor launchDescriptor
		if err := json.Unmarshal(raw, &descriptor); err != nil {
			return launchDescriptor{}, fmt.Errorf("parse runs-on-launch descriptor: %w", err)
		}
		if err := descriptor.validate(); err != nil {
			return launchDescriptor{}, err
		}
		return descriptor, nil
	}

	return launchDescriptor{}, fmt.Errorf("user data does not contain %q", descriptorPrefix)
}

func (d launchDescriptor) validate() error {
	if d.Version != 1 {
		return fmt.Errorf("unsupported runs-on-launch descriptor version %d", d.Version)
	}
	if !bootstrapVersionPattern.MatchString(d.BootstrapVersion) {
		return fmt.Errorf("invalid bootstrap version %q", d.BootstrapVersion)
	}
	if !strings.HasPrefix(d.AgentS3URL, "s3://") || strings.ContainsAny(d.AgentS3URL, "\r\n\x00") {
		return fmt.Errorf("invalid agent S3 URL")
	}
	if d.PostExec != "" && d.PostExec != "shutdown" {
		return fmt.Errorf("invalid post_exec %q", d.PostExec)
	}
	for name := range d.Environment {
		if _, ok := allowedEnvironment[name]; !ok {
			return fmt.Errorf("environment variable %q is not allowed", name)
		}
	}
	return nil
}
