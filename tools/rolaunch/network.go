package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"time"
)

const (
	defaultSysClassNetPath     = "/sys/class/net"
	defaultNetworkdLinksPath   = "/run/systemd/netif/links"
	defaultNetworkLogInterval  = 10 * time.Second
	defaultNetworkRecoverAfter = 15 * time.Second
	defaultNetworkRecoverEvery = 30 * time.Second
	// Recovery runs inside the readiness loop, so a command stuck on D-Bus early
	// in boot must not hold up IMDS polling for long.
	defaultNetworkRecoverTimeout = 5 * time.Second
	networkRecoverReserve        = time.Second
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

// networkRecoveryCommands picks how to nudge a boot that has no route to IMDS.
// networkd only configures a link once udev has announced it, and reconfigure
// is a no-op until then, so links networkd has not taken up yet get their udev
// add event replayed instead. Links it did take up are configured again, which
// recovers one it gave up on. Without any interface, the Ethernet PCI devices
// are re-announced so udev loads the driver and creates the interface.
func networkRecoveryCommands(links []networkLink) [][]string {
	if len(links) == 0 {
		return [][]string{{
			"udevadm", "trigger", "--action=add",
			"--subsystem-match=pci", "--attr-match=class=" + pciEthernetControllerClass,
		}}
	}
	var commands [][]string
	reconfigure := []string{"networkctl", "reconfigure"}
	for _, link := range links {
		switch link.NetworkdAdmin {
		case "", "pending", "initialized":
			commands = append(commands, []string{"udevadm", "trigger", "--action=add", "/sys/class/net/" + link.Name})
		default:
			reconfigure = append(reconfigure, link.Name)
		}
	}
	if len(reconfigure) > 2 {
		commands = append(commands, reconfigure)
	}
	return commands
}

// isNetworkUnreachable reports whether an IMDS attempt failed because the
// instance has no route to it, the only failure network recovery can help with.
// Recovery restarts DHCP, so any other error must leave a working link alone.
func isNetworkUnreachable(err error) bool {
	return errors.Is(err, syscall.ENETUNREACH) || errors.Is(err, syscall.EHOSTUNREACH)
}

func runNetworkRecoveryCommand(ctx context.Context, command []string) error {
	cmd := exec.CommandContext(ctx, command[0], command[1:]...)
	cmd.WaitDelay = time.Second
	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("%s: %w: %s", strings.Join(command, " "), err, strings.TrimSpace(string(output)))
	}
	return nil
}

// networkWatchdog runs alongside the IMDS readiness loop. It logs the state of
// every interface periodically, so a boot that never reaches IMDS shows why,
// and asks the system to configure the network again when it stays down.
type networkWatchdog struct {
	readLinks      func() []networkLink
	runCommand     func(context.Context, []string) error
	logEvery       time.Duration
	recoverAfter   time.Duration
	recoverEvery   time.Duration
	recoverTimeout time.Duration

	started     time.Time
	lastLog     time.Time
	lastRecover time.Time
}

func newNetworkWatchdog() *networkWatchdog {
	return &networkWatchdog{
		readLinks: func() []networkLink {
			return readNetworkLinks(defaultSysClassNetPath, defaultNetworkdLinksPath)
		},
		runCommand:     runNetworkRecoveryCommand,
		logEvery:       defaultNetworkLogInterval,
		recoverAfter:   defaultNetworkRecoverAfter,
		recoverEvery:   defaultNetworkRecoverEvery,
		recoverTimeout: defaultNetworkRecoverTimeout,
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
	recoverDue := isNetworkUnreachable(err) &&
		waited >= w.recoverAfter &&
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
		for _, command := range networkRecoveryCommands(links) {
			// Leave the readiness loop time to try IMDS again over a link the
			// command may just have restored.
			if deadline, ok := ctx.Deadline(); ok && time.Until(deadline) < w.recoverTimeout+networkRecoverReserve {
				log.Printf("skipping network recovery, too close to the readiness deadline: %s", strings.Join(command, " "))
				continue
			}
			log.Printf("attempting network recovery: %s", strings.Join(command, " "))
			commandCtx, cancel := context.WithTimeout(ctx, w.recoverTimeout)
			if err := w.runCommand(commandCtx, command); err != nil {
				log.Printf("network recovery failed: %v", err)
			}
			cancel()
		}
	}
}
