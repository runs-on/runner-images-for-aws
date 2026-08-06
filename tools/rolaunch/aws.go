package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"path/filepath"
	"strings"
	"sync"
	"time"

	aws "github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/aws/retry"
	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/feature/ec2/imds"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
	ec2types "github.com/aws/aws-sdk-go-v2/service/ec2/types"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	smithyhttp "github.com/aws/smithy-go/transport/http"
)

const (
	imdsPublicKeysMetadataPath = "public-keys"
	imdsPublicKeySuffix        = "openssh-key"
	imdsLocalHostnamePath      = "local-hostname"
)

type awsState struct {
	mu             sync.Mutex
	metadataClient *imds.Client
	ec2Clients     map[string]*ec2.Client
	s3Clients      map[string]*s3.Client
}

type bootstrapPrefetchSpec struct {
	BootstrapTag      string
	BootstrapPath     string
	AgentBinaryName   string
	S3Bucket          string
	S3Key             string
	DownloadedBinPath string
}

type s3ObjectGetter interface {
	GetObject(context.Context, *s3.GetObjectInput, ...func(*s3.Options)) (*s3.GetObjectOutput, error)
}

func newAWSState() *awsState {
	return &awsState{
		ec2Clients: make(map[string]*ec2.Client),
		s3Clients:  make(map[string]*s3.Client),
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
	if !cfg.isFullMode() {
		return identity, nil
	}

	localHostname, found, err := s.fetchMetadataPath(ctx, cfg, imdsLocalHostnamePath)
	if err != nil {
		return instanceIdentity{}, err
	}
	if found {
		identity.LocalHostname = strings.TrimSpace(string(localHostname))
	}

	return identity, nil
}

func (s *awsState) enrichOptionalInstanceIdentity(ctx context.Context, cfg config, identity instanceIdentity) (instanceIdentity, error) {
	tagsTask := startAsync(func() (map[string]string, error) {
		return s.fetchInstanceTags(ctx, cfg, identity.Region, identity.InstanceID)
	})

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

	tags, err := tagsTask.wait()
	if err != nil {
		return instanceIdentity{}, err
	}
	identity.Tags = tags

	return identity, nil
}

type ec2TagDescriber interface {
	DescribeTags(context.Context, *ec2.DescribeTagsInput, ...func(*ec2.Options)) (*ec2.DescribeTagsOutput, error)
}

func (s *awsState) fetchInstanceTags(ctx context.Context, cfg config, region, instanceID string) (map[string]string, error) {
	client, err := s.ec2ClientFor(ctx, cfg, region)
	if err != nil {
		return nil, err
	}
	return describeInstanceTags(ctx, client, instanceID)
}

func describeInstanceTags(ctx context.Context, client ec2TagDescriber, instanceID string) (map[string]string, error) {
	output, err := client.DescribeTags(ctx, &ec2.DescribeTagsInput{Filters: []ec2types.Filter{{
		Name:   aws.String("resource-id"),
		Values: []string{instanceID},
	}}})
	if err != nil {
		return nil, fmt.Errorf("describe tags for instance %s: %w", instanceID, err)
	}

	tags := make(map[string]string, len(output.Tags))
	for _, tag := range output.Tags {
		if tag.Key == nil || tag.Value == nil {
			continue
		}
		tags[*tag.Key] = *tag.Value
	}
	return tags, nil
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
	s.mu.Unlock()

	awsCfg, err := awsconfig.LoadDefaultConfig(ctx, append(metadataLoadOptions(cfg), awsconfig.WithRegion(region))...)
	if err != nil {
		err = fmt.Errorf("load AWS config for region %s: %w", region, err)
		return nil, err
	}

	awsCfg.Retryer = func() aws.Retryer {
		return retry.AddWithMaxAttempts(retry.NewStandard(), 1)
	}

	client := s3.NewFromConfig(awsCfg)
	s.mu.Lock()
	s.s3Clients[region] = client
	s.mu.Unlock()
	return client, nil
}

func (s *awsState) ec2ClientFor(ctx context.Context, cfg config, region string) (*ec2.Client, error) {
	s.mu.Lock()
	if client, ok := s.ec2Clients[region]; ok {
		s.mu.Unlock()
		return client, nil
	}
	s.mu.Unlock()

	awsCfg, err := awsconfig.LoadDefaultConfig(ctx, append(metadataLoadOptions(cfg), awsconfig.WithRegion(region))...)
	if err != nil {
		return nil, fmt.Errorf("load AWS config for region %s: %w", region, err)
	}
	awsCfg.Retryer = func() aws.Retryer {
		return retry.AddWithMaxAttempts(retry.NewStandard(), 1)
	}

	client := ec2.NewFromConfig(awsCfg)
	s.mu.Lock()
	s.ec2Clients[region] = client
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
