package main

import (
	"bytes"
	"fmt"
	"net"
	"os"
	"strings"
)

const (
	defaultHostnamePath = "/etc/hostname"
	defaultHostsPath    = "/etc/hosts"
)

func configureInstanceHostname(identity instanceIdentity) error {
	return configureInstanceHostnameAtPaths(
		identity,
		defaultHostnamePath,
		defaultHostsPath,
		os.Hostname,
		setRuntimeHostname,
	)
}

func configureInstanceHostnameAtPaths(
	identity instanceIdentity,
	hostnamePath string,
	hostsPath string,
	currentHostname func() (string, error),
	setHostname func(string) error,
) error {
	hostname, err := hostnameForInstance(identity)
	if err != nil {
		return err
	}

	staticHostname, err := os.ReadFile(hostnamePath)
	if err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("read static hostname: %w", err)
	}
	current, err := currentHostname()
	if err != nil {
		return fmt.Errorf("read runtime hostname: %w", err)
	}

	hosts, err := os.ReadFile(hostsPath)
	if err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("read hosts file: %w", err)
	}
	updatedHosts := renderHostsFile(hosts, hostname, string(staticHostname), current)

	if err := writeFileIfChanged(hostnamePath, []byte(hostname+"\n"), 0o644); err != nil {
		return fmt.Errorf("write static hostname: %w", err)
	}
	if err := writeFileIfChanged(hostsPath, updatedHosts, 0o644); err != nil {
		return fmt.Errorf("write hosts file: %w", err)
	}

	if current == hostname {
		return nil
	}
	if err := setHostname(hostname); err != nil {
		return fmt.Errorf("set runtime hostname to %s: %w", hostname, err)
	}

	return nil
}

func hostnameForInstance(identity instanceIdentity) (string, error) {
	if hostname, ok := metadataHostnameLabel(identity.LocalHostname); ok {
		return hostname, nil
	}

	privateIP := net.ParseIP(strings.TrimSpace(identity.PrivateIP))
	if ipv4 := privateIP.To4(); ipv4 != nil {
		return "ip-" + strings.ReplaceAll(ipv4.String(), ".", "-"), nil
	}

	if hostname, ok := metadataHostnameLabel(identity.InstanceID); ok {
		return hostname, nil
	}
	if ipv6 := privateIP.To16(); ipv6 != nil {
		return fmt.Sprintf("ip6-%x", []byte(ipv6)), nil
	}

	return "", fmt.Errorf(
		"cannot derive instance hostname from local hostname %q, private IP %q, or instance ID %q",
		identity.LocalHostname,
		identity.PrivateIP,
		identity.InstanceID,
	)
}

func metadataHostnameLabel(value string) (string, bool) {
	value = strings.TrimRight(strings.TrimSpace(value), ".")
	if value == "" || strings.ContainsAny(value, " \t\r\n") {
		return "", false
	}

	labels := strings.Split(value, ".")
	for _, label := range labels {
		if !validHostnameLabel(label) {
			return "", false
		}
	}
	return labels[0], true
}

func validHostnameLabel(label string) bool {
	if len(label) == 0 || len(label) > 63 || label[0] == '-' || label[len(label)-1] == '-' {
		return false
	}
	for _, char := range label {
		if (char >= 'a' && char <= 'z') ||
			(char >= 'A' && char <= 'Z') ||
			(char >= '0' && char <= '9') ||
			char == '-' {
			continue
		}
		return false
	}
	return true
}

func renderHostsFile(raw []byte, hostname string, previousHostnames ...string) []byte {
	body := strings.TrimRight(string(raw), "\n")
	lines := make([]string, 0)
	if body != "" {
		lines = strings.Split(body, "\n")
	}

	updated := make([]string, 0, len(lines)+2)
	hasLocalhost := false
	hasInstanceHostname := hostsFileMapsName(lines, "127.0.1.1", hostname)
	previousLabels := previousHostnameLabels(previousHostnames, hostname)
	for _, line := range lines {
		fields := hostsLineFields(line)
		if len(fields) > 1 && fields[0] == "127.0.0.1" && containsString(fields[1:], "localhost") {
			hasLocalhost = true
		}
		if len(fields) > 1 && fields[0] == "127.0.1.1" {
			names := make([]string, 0, len(fields)-1)
			removedPreviousHostname := false
			for _, name := range fields[1:] {
				if previousLabels[hostnameLabelKey(name)] && !strings.EqualFold(name, hostname) {
					removedPreviousHostname = true
					continue
				}
				names = append(names, name)
			}

			if removedPreviousHostname {
				if !hasInstanceHostname {
					names = append([]string{hostname}, names...)
					hasInstanceHostname = true
				}
				if len(names) > 0 {
					updated = append(updated, renderHostsMapping("127.0.1.1", names, hostsLineComment(line)))
				} else if comment := hostsLineComment(line); comment != "" {
					updated = append(updated, comment)
				}
				continue
			}
		}
		updated = append(updated, line)
	}

	if !hasLocalhost {
		updated = append([]string{"127.0.0.1 localhost"}, updated...)
	}
	if !hasInstanceHostname {
		updated = append(updated, "127.0.1.1 "+hostname)
	}

	return []byte(strings.Join(updated, "\n") + "\n")
}

func previousHostnameLabels(values []string, target string) map[string]bool {
	labels := make(map[string]bool, len(values))
	for _, value := range values {
		value = strings.TrimSpace(value)
		if strings.ContainsAny(value, " \t\r\n") {
			continue
		}
		label := hostnameLabelKey(value)
		if label == "" || label == "localhost" || label == "(none)" || strings.EqualFold(label, target) {
			continue
		}
		labels[label] = true
	}
	return labels
}

func hostnameLabelKey(value string) string {
	value = strings.TrimRight(strings.TrimSpace(value), ".")
	label, _, _ := strings.Cut(value, ".")
	if !validHostnameLabel(label) {
		return ""
	}
	return strings.ToLower(label)
}

func hostsLineComment(line string) string {
	_, comment, found := strings.Cut(line, "#")
	if !found {
		return ""
	}
	return "#" + comment
}

func renderHostsMapping(address string, names []string, comment string) string {
	line := address + " " + strings.Join(names, " ")
	if comment != "" {
		line += " " + comment
	}
	return line
}

func hostsFileMapsName(lines []string, address string, name string) bool {
	for _, line := range lines {
		fields := hostsLineFields(line)
		if len(fields) > 1 && fields[0] == address && containsString(fields[1:], name) {
			return true
		}
	}
	return false
}

func hostsLineFields(line string) []string {
	content, _, _ := strings.Cut(line, "#")
	return strings.Fields(content)
}

func containsString(values []string, target string) bool {
	for _, value := range values {
		if value == target {
			return true
		}
	}
	return false
}

func writeFileIfChanged(path string, content []byte, mode os.FileMode) error {
	existing, err := os.ReadFile(path)
	if err == nil && bytes.Equal(existing, content) {
		return nil
	}
	if err != nil && !os.IsNotExist(err) {
		return err
	}
	return os.WriteFile(path, content, mode)
}
