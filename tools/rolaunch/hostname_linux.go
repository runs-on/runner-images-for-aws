//go:build linux

package main

import "syscall"

func setRuntimeHostname(hostname string) error {
	return syscall.Sethostname([]byte(hostname))
}
