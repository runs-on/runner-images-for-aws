//go:build !linux

package main

import "fmt"

func setRuntimeHostname(string) error {
	return fmt.Errorf("setting the runtime hostname is only supported on Linux")
}
