package main

import (
	"context"
	"fmt"
	"os/exec"
	"strings"
	"time"
)

const defaultBasicTargetPollInterval = 50 * time.Millisecond

type basicTargetStateProbe func(context.Context) (string, error)

func waitForBasicTarget(ctx context.Context) error {
	return waitForBasicTargetWithProbe(ctx, defaultBasicTargetPollInterval, systemdBasicTargetState)
}

func waitForBasicTargetWithProbe(ctx context.Context, interval time.Duration, probe basicTargetStateProbe) error {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for {
		state, err := probe(ctx)
		if err != nil {
			return fmt.Errorf("query basic.target state: %w", err)
		}
		switch state {
		case "active":
			return nil
		case "inactive", "activating":
		case "failed", "deactivating":
			return fmt.Errorf("basic.target entered %s state", state)
		default:
			return fmt.Errorf("unexpected basic.target state %q", state)
		}

		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-ticker.C:
		}
	}
}

func systemdBasicTargetState(ctx context.Context) (string, error) {
	output, err := exec.CommandContext(
		ctx,
		"/usr/bin/systemctl",
		"show",
		"--property=ActiveState",
		"--value",
		"basic.target",
	).CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("systemctl show basic.target: %w (%s)", err, strings.TrimSpace(string(output)))
	}
	return strings.TrimSpace(string(output)), nil
}
