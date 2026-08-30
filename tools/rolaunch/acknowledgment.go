package main

import (
	"encoding/json"
	"os"
	"strings"
)

type prefetchAcknowledgment struct {
	ReceiptVersion int    `json:"receiptVersion"`
	ObjectKey      string `json:"objectKey"`
	InstanceID     string `json:"instanceId"`
	AssignmentID   string `json:"assignmentId,omitempty"`
}

func acknowledgesReceipt(path string, receipt prefetchReceipt) bool {
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm() != 0o600 {
		return false
	}
	body, err := os.ReadFile(path)
	if err != nil {
		return false
	}
	var acknowledgment prefetchAcknowledgment
	if err := json.Unmarshal(body, &acknowledgment); err != nil {
		return false
	}
	return acknowledgment.ReceiptVersion == receipt.ReceiptVersion &&
		acknowledgment.ObjectKey == receipt.ObjectKey &&
		acknowledgment.InstanceID == receipt.InstanceID &&
		strings.TrimSpace(acknowledgment.AssignmentID) == strings.TrimSpace(receipt.AssignmentID)
}
