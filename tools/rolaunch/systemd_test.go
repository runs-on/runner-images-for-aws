package main

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"
)

func TestWaitForBasicTargetWaitsForActiveState(t *testing.T) {
	t.Parallel()

	states := []string{"inactive", "activating", "active"}
	calls := 0
	err := waitForBasicTargetWithProbe(context.Background(), time.Millisecond, func(context.Context) (string, error) {
		state := states[calls]
		calls++
		return state, nil
	})
	if err != nil {
		t.Fatalf("waitForBasicTargetWithProbe returned error: %v", err)
	}
	if calls != len(states) {
		t.Fatalf("unexpected probe call count %d", calls)
	}
}

func TestWaitForBasicTargetFailsClosed(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name      string
		state     string
		probeErr  error
		wantError string
	}{
		{name: "failed", state: "failed", wantError: "basic.target entered failed state"},
		{name: "deactivating", state: "deactivating", wantError: "basic.target entered deactivating state"},
		{name: "unexpected", state: "maintenance", wantError: `unexpected basic.target state "maintenance"`},
		{name: "probe error", probeErr: fmt.Errorf("private manager unavailable"), wantError: "query basic.target state: private manager unavailable"},
	}

	for _, test := range tests {
		test := test
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			err := waitForBasicTargetWithProbe(context.Background(), time.Millisecond, func(context.Context) (string, error) {
				return test.state, test.probeErr
			})
			if err == nil || !strings.Contains(err.Error(), test.wantError) {
				t.Fatalf("unexpected error: %v", err)
			}
		})
	}
}

func TestWaitForBasicTargetHonorsContextCancellation(t *testing.T) {
	t.Parallel()

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	err := waitForBasicTargetWithProbe(ctx, time.Millisecond, func(context.Context) (string, error) {
		return "activating", nil
	})
	if err == nil || !strings.Contains(err.Error(), context.Canceled.Error()) {
		t.Fatalf("unexpected error: %v", err)
	}
}
