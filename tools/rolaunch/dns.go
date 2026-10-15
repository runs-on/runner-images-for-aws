package main

import (
	"context"
	"net"
	"time"
)

// dnsQueryTimeout is how long rolaunch waits for a DNS answer before asking
// again. Go's resolver otherwise waits 5 s, the resolv.conf default (a
// CGO_ENABLED=0 build ignores RES_OPTIONS). A few seconds into boot, a query
// can go unanswered while the next one is answered at once: with 5 s, the
// agent prefetch then takes 5.3 s instead of 0.4 s. Minimal mode writes
// timeout:1 to resolv.conf for the same reason; full mode keeps the
// systemd-resolved stub, so rolaunch sets the timeout on its own resolver.
const dnsQueryTimeout = time.Second

// newQuickRetryResolver returns a Go resolver whose queries wait at most
// queryTimeout for an answer; resolv.conf's attempts still apply. A non-empty
// server replaces the configured nameservers (tests only).
func newQuickRetryResolver(queryTimeout time.Duration, server string) *net.Resolver {
	return &net.Resolver{
		PreferGo: true,
		Dial: func(ctx context.Context, network, address string) (net.Conn, error) {
			if server != "" {
				address = server
			}
			var dialer net.Dialer
			conn, err := dialer.DialContext(ctx, network, address)
			if err != nil {
				return nil, err
			}
			// The resolver sets the query's deadline on the connection, and
			// sends UDP only to a connection that is still a net.PacketConn.
			if udp, ok := conn.(*net.UDPConn); ok {
				return cappedUDPConn{UDPConn: udp, limit: queryTimeout}, nil
			}
			return cappedConn{Conn: conn, limit: queryTimeout}, nil
		},
	}
}

func capDeadline(t time.Time, limit time.Duration) time.Time {
	if max := time.Now().Add(limit); t.IsZero() || t.After(max) {
		return max
	}
	return t
}

type cappedUDPConn struct {
	*net.UDPConn
	limit time.Duration
}

func (c cappedUDPConn) SetDeadline(t time.Time) error {
	return c.UDPConn.SetDeadline(capDeadline(t, c.limit))
}

type cappedConn struct {
	net.Conn
	limit time.Duration
}

func (c cappedConn) SetDeadline(t time.Time) error {
	return c.Conn.SetDeadline(capDeadline(t, c.limit))
}
