package main

import (
	"encoding/json"
	"path/filepath"
	"testing"
)

func TestAcknowledgesReceiptRequiresExactObjectIdentityAndAssignment(t *testing.T) {
	path := filepath.Join(t.TempDir(), "runner-config.ack")
	receipt := prefetchReceipt{ReceiptVersion: 1, ObjectKey: "runners/role:i/runner-config.json", InstanceID: "i-1", AssignmentID: "new"}
	for name, acknowledgment := range map[string]prefetchAcknowledgment{
		"stale assignment": {ReceiptVersion: 1, ObjectKey: receipt.ObjectKey, InstanceID: receipt.InstanceID, AssignmentID: "old"},
		"stale instance":   {ReceiptVersion: 1, ObjectKey: receipt.ObjectKey, InstanceID: "i-old", AssignmentID: receipt.AssignmentID},
		"exact":            {ReceiptVersion: 1, ObjectKey: receipt.ObjectKey, InstanceID: receipt.InstanceID, AssignmentID: receipt.AssignmentID},
	} {
		t.Run(name, func(t *testing.T) {
			body, err := json.Marshal(acknowledgment)
			if err != nil {
				t.Fatal(err)
			}
			if err := writeAtomicFile(path, body, 0o600); err != nil {
				t.Fatal(err)
			}
			if got, want := acknowledgesReceipt(path, receipt), name == "exact"; got != want {
				t.Fatalf("acknowledgesReceipt() = %v, want %v", got, want)
			}
		})
	}
}
