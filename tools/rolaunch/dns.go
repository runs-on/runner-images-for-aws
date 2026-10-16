package main

import (
	"context"
	"errors"
	"net"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// rolaunch resolves the names of its own requests itself, against the
// servers systemd-resolved forwards to, and waits at most dnsQueryTimeout
// for each answer.
//
// A few seconds into boot, the VPC resolver can be unreachable for up to
// about 2 s. systemd-resolved then waits 5 s before its first retry, since
// it has no round-trip time for the server yet, and every query for the same
// name joins that pending transaction: its stub answers nothing for 5 s, and
// the agent prefetch takes 5.3 s instead of 0.4 s. Asked directly, again
// every 250 ms, the same server answers within 0.75 to 1.8 s.
//
// Go's resolver would also wait 5 s itself (the resolv.conf default; a
// CGO_ENABLED=0 build ignores RES_OPTIONS), hence the timeout on its
// connections. It asks twice for the name and twice for its search-domain
// form, so a lookup fails after about 1 s and
// downloadS3ObjectToFileWithRetry asks again. Minimal mode has no
// systemd-resolved: its resolv.conf already names the VPC resolver, and only
// the timeout applies.
//
// A server that always takes longer than dnsQueryTimeout to answer, such as
// a custom resolver far away, would never be heard. Once queries have gone
// unanswered for dnsQuickRetryWindow, longer than the outage above, the
// resolver keeps its own timeouts for the rest of the run.
const (
	dnsQueryTimeout        = 250 * time.Millisecond
	dnsQuickRetryWindow    = 3 * time.Second
	resolvedUpstreamConfig = "/run/systemd/resolve/resolv.conf"
)

// upstreamNameservers returns the nameservers of a resolv.conf, here the one
// systemd-resolved writes with the servers it forwards to. A missing file
// or one without nameservers returns none.
func upstreamNameservers(path string) []string {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	var servers []string
	for _, line := range strings.Split(string(raw), "\n") {
		if fields := strings.Fields(line); len(fields) >= 2 && fields[0] == "nameserver" {
			servers = append(servers, net.JoinHostPort(fields[1], "53"))
		}
	}
	return servers
}

// newQuickRetryResolver returns a Go resolver whose queries wait at most
// queryTimeout for an answer, until queries have gone unanswered for window.
// With servers, its queries go to them in turn instead of to the configured
// nameservers.
func newQuickRetryResolver(queryTimeout, window time.Duration, servers []string) *net.Resolver {
	var next atomic.Uint32
	quick := &quickRetry{limit: queryTimeout, window: window}
	return &net.Resolver{
		PreferGo: true,
		Dial: func(ctx context.Context, network, address string) (net.Conn, error) {
			if len(servers) > 0 {
				address = servers[int(next.Add(1)-1)%len(servers)]
			}
			limit := quick.currentLimit()
			if limit > 0 {
				// A TCP connection to a silent server would otherwise take
				// the resolver's own timeout to fail.
				var cancel context.CancelFunc
				ctx, cancel = context.WithTimeout(ctx, limit)
				defer cancel()
			}
			var dialer net.Dialer
			conn, err := dialer.DialContext(ctx, network, address)
			if err != nil {
				quick.observe(err)
				return nil, err
			}
			// The resolver sets the query's deadline on the connection, and
			// sends UDP only to a connection that is still a net.PacketConn.
			if udp, ok := conn.(*net.UDPConn); ok {
				return cappedUDPConn{UDPConn: udp, quick: quick, limit: limit}, nil
			}
			return cappedConn{Conn: conn, quick: quick, limit: limit}, nil
		},
	}
}

// quickRetry tracks whether the servers answer within the quick limit.
type quickRetry struct {
	limit  time.Duration
	window time.Duration

	mu           sync.Mutex
	failingSince time.Time // first unanswered query since the last answer
	relaxed      bool      // queries went unanswered for window: no limit
}

// currentLimit returns the limit for a new query, or 0 for none.
func (q *quickRetry) currentLimit() time.Duration {
	q.mu.Lock()
	defer q.mu.Unlock()
	if q.relaxed {
		return 0
	}
	return q.limit
}

// observe records the outcome of a read or a dial: an answer ends the
// current run of timeouts, and timeouts lasting window lift the limit.
func (q *quickRetry) observe(err error) {
	var netErr net.Error
	timedOut := errors.As(err, &netErr) && netErr.Timeout()
	if err != nil && !timedOut {
		return
	}
	q.mu.Lock()
	defer q.mu.Unlock()
	switch now := time.Now(); {
	case err == nil:
		q.failingSince = time.Time{}
	case q.failingSince.IsZero():
		q.failingSince = now
	case now.Sub(q.failingSince) >= q.window:
		q.relaxed = true
	}
}

func capDeadline(t time.Time, limit time.Duration) time.Time {
	if limit <= 0 {
		return t
	}
	if max := time.Now().Add(limit); t.IsZero() || t.After(max) {
		return max
	}
	return t
}

type cappedUDPConn struct {
	*net.UDPConn
	quick *quickRetry
	limit time.Duration
}

func (c cappedUDPConn) SetDeadline(t time.Time) error {
	return c.UDPConn.SetDeadline(capDeadline(t, c.limit))
}

func (c cappedUDPConn) Read(b []byte) (int, error) {
	n, err := c.UDPConn.Read(b)
	c.quick.observe(err)
	return n, err
}

type cappedConn struct {
	net.Conn
	quick *quickRetry
	limit time.Duration
}

func (c cappedConn) SetDeadline(t time.Time) error {
	return c.Conn.SetDeadline(capDeadline(t, c.limit))
}

func (c cappedConn) Read(b []byte) (int, error) {
	n, err := c.Conn.Read(b)
	c.quick.observe(err)
	return n, err
}
