package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

const (
	defaultSysClassNetPath     = "/sys/class/net"
	defaultNetworkdLinksPath   = "/run/systemd/netif/links"
	defaultNetworkLogInterval  = 10 * time.Second
	defaultNetworkRecoverAfter = 15 * time.Second
	defaultNetworkRecoverEvery = 30 * time.Second
	// PCI class code of an Ethernet controller, which is what ENA reports.
	pciEthernetControllerClass = "0x020000"
)

// networkLink is what the kernel and systemd-networkd report about one
// interface while rolaunch waits for IMDS.
type networkLink struct {
	Name          string
	Index         string
	Driver        string
	OperState     string
	Carrier       string
	NetworkdAdmin string
	NetworkdOper  string
}

func (l networkLink) String() string {
	return fmt.Sprintf(
		"%s(ifindex=%s driver=%s operstate=%s carrier=%s networkd=%s/%s)",
		l.Name,
		valueOrUnknown(l.Index),
		valueOrUnknown(l.Driver),
		valueOrUnknown(l.OperState),
		valueOrUnknown(l.Carrier),
		valueOrUnknown(l.NetworkdAdmin),
		valueOrUnknown(l.NetworkdOper),
	)
}

func valueOrUnknown(value string) string {
	if value == "" {
		return "?"
	}
	return value
}

// readNetworkLinks lists every non-loopback interface. It never fails: a
// missing file only leaves the matching field unknown.
func readNetworkLinks(sysClassNet, networkdLinks string) []networkLink {
	entries, err := os.ReadDir(sysClassNet)
	if err != nil {
		return nil
	}

	links := make([]networkLink, 0, len(entries))
	for _, entry := range entries {
		name := entry.Name()
		if name == "lo" {
			continue
		}
		dir := filepath.Join(sysClassNet, name)
		link := networkLink{
			Name:      name,
			Index:     readTrimmedFile(filepath.Join(dir, "ifindex")),
			OperState: readTrimmedFile(filepath.Join(dir, "operstate")),
			Carrier:   readTrimmedFile(filepath.Join(dir, "carrier")),
		}
		if driver, err := os.Readlink(filepath.Join(dir, "device", "driver")); err == nil {
			link.Driver = filepath.Base(driver)
		}
		if link.Index != "" {
			state := readKeyValueFile(filepath.Join(networkdLinks, link.Index))
			link.NetworkdAdmin = state["ADMIN_STATE"]
			link.NetworkdOper = state["OPER_STATE"]
		}
		links = append(links, link)
	}
	sort.Slice(links, func(i, j int) bool { return links[i].Name < links[j].Name })
	return links
}

func readTrimmedFile(path string) string {
	body, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(body))
}

func readKeyValueFile(path string) map[string]string {
	values := make(map[string]string)
	body, err := os.ReadFile(path)
	if err != nil {
		return values
	}
	for line := range strings.SplitSeq(string(body), "\n") {
		key, value, ok := strings.Cut(strings.TrimSpace(line), "=")
		if ok {
			values[key] = value
		}
	}
	return values
}

func describeNetworkLinks(links []networkLink) string {
	if len(links) == 0 {
		return "no network interfaces"
	}
	parts := make([]string, 0, len(links))
	for _, link := range links {
		parts = append(parts, link.String())
	}
	return strings.Join(parts, ", ")
}

// networkRecoveryCommand picks how to nudge a boot that has no route to IMDS.
// With interfaces present, networkd is asked to configure them again, which
// recovers a link it gave up on. Without any, the Ethernet PCI devices are
// re-announced so udev loads the driver and creates the interface.
func networkRecoveryCommand(links []networkLink) []string {
	if len(links) == 0 {
		return []string{
			"udevadm", "trigger", "--action=add",
			"--subsystem-match=pci", "--attr-match=class=" + pciEthernetControllerClass,
		}
	}
	command := []string{"networkctl", "reconfigure"}
	for _, link := range links {
		command = append(command, link.Name)
	}
	return command
}

func runNetworkRecoveryCommand(ctx context.Context, command []string) error {
	output, err := exec.CommandContext(ctx, command[0], command[1:]...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("%s: %w: %s", strings.Join(command, " "), err, strings.TrimSpace(string(output)))
	}
	return nil
}

// networkWatchdog runs alongside the IMDS readiness loop. It logs the state of
// every interface periodically, so a boot that never reaches IMDS shows why,
// and asks the system to configure the network again when it stays down.
type networkWatchdog struct {
	readLinks    func() []networkLink
	runCommand   func(context.Context, []string) error
	logEvery     time.Duration
	recoverAfter time.Duration
	recoverEvery time.Duration

	started     time.Time
	lastLog     time.Time
	lastRecover time.Time
}

func newNetworkWatchdog() *networkWatchdog {
	return &networkWatchdog{
		readLinks: func() []networkLink {
			return readNetworkLinks(defaultSysClassNetPath, defaultNetworkdLinksPath)
		},
		runCommand:   runNetworkRecoveryCommand,
		logEvery:     defaultNetworkLogInterval,
		recoverAfter: defaultNetworkRecoverAfter,
		recoverEvery: defaultNetworkRecoverEvery,
	}
}

// observe is called after every failed IMDS attempt.
func (w *networkWatchdog) observe(ctx context.Context, now time.Time, err error) {
	if w.started.IsZero() {
		w.started = now
		w.lastLog = now
		return
	}

	waited := now.Sub(w.started)
	logDue := now.Sub(w.lastLog) >= w.logEvery
	recoverDue := waited >= w.recoverAfter &&
		(w.lastRecover.IsZero() || now.Sub(w.lastRecover) >= w.recoverEvery)
	if !logDue && !recoverDue {
		return
	}

	links := w.readLinks()
	if logDue {
		w.lastLog = now
		log.Printf("still waiting for IMDS after %s: %v; links: %s", waited.Round(time.Second), err, describeNetworkLinks(links))
	}
	if recoverDue {
		w.lastRecover = now
		command := networkRecoveryCommand(links)
		log.Printf("attempting network recovery: %s", strings.Join(command, " "))
		if err := w.runCommand(ctx, command); err != nil {
			log.Printf("network recovery failed: %v", err)
		}
	}
}
