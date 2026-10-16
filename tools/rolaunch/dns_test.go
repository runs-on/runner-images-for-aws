package main

import (
	"context"
	"encoding/binary"
	"net"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

// A DNS server that ignores the first A query and answers every later one,
// like the unanswered query seen a few seconds into boot. With a delay, it
// answers every query that late instead, like a slow but working server.
type lossyDNSServer struct {
	conn     *net.UDPConn
	delay    time.Duration
	mu       sync.Mutex
	aQueries int
}

func startLossyDNSServer(t *testing.T) *lossyDNSServer {
	return startDNSServer(t, 0)
}

func startDNSServer(t *testing.T, delay time.Duration) *lossyDNSServer {
	t.Helper()
	conn, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	t.Cleanup(func() { _ = conn.Close() })
	s := &lossyDNSServer{conn: conn, delay: delay}
	go s.serve()
	return s
}

func (s *lossyDNSServer) serve() {
	buf := make([]byte, 1500)
	for {
		n, addr, err := s.conn.ReadFromUDP(buf)
		if err != nil {
			return
		}
		query := append([]byte(nil), buf[:n]...)
		end := 12
		for end < len(query) && query[end] != 0 {
			end += int(query[end]) + 1
		}
		end += 5 // root label, type, class
		if end > len(query) {
			continue
		}
		qtype := binary.BigEndian.Uint16(query[end-4 : end-2])
		if qtype == 1 {
			s.mu.Lock()
			s.aQueries++
			first := s.aQueries == 1
			s.mu.Unlock()
			if first && s.delay == 0 {
				continue
			}
		}
		// Header: same id, response with recursion, one question, one answer
		// for A (192.0.2.1) and none for anything else.
		resp := append([]byte(nil), query[:end]...)
		binary.BigEndian.PutUint16(resp[2:], 0x8180)
		binary.BigEndian.PutUint16(resp[4:], 1)
		binary.BigEndian.PutUint16(resp[8:], 0)
		binary.BigEndian.PutUint16(resp[10:], 0)
		if qtype == 1 {
			binary.BigEndian.PutUint16(resp[6:], 1)
			resp = append(resp, 0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 192, 0, 2, 1)
		} else {
			binary.BigEndian.PutUint16(resp[6:], 0)
		}
		if s.delay > 0 {
			go func() {
				time.Sleep(s.delay)
				_, _ = s.conn.WriteToUDP(resp, addr)
			}()
			continue
		}
		_, _ = s.conn.WriteToUDP(resp, addr)
	}
}

func (s *lossyDNSServer) queriesForA() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.aQueries
}

func TestQuickRetryResolverAsksAgainAfterTheQueryTimeout(t *testing.T) {
	t.Parallel()

	server := startLossyDNSServer(t)
	resolver := newQuickRetryResolver(200*time.Millisecond, time.Minute, []string{server.conn.LocalAddr().String()})

	start := time.Now()
	addrs, err := resolver.LookupHost(context.Background(), "bucket.s3.us-east-1.amazonaws.com")
	elapsed := time.Since(start)
	if err != nil {
		t.Fatalf("lookup: %v", err)
	}
	if len(addrs) != 1 || addrs[0] != "192.0.2.1" {
		t.Fatalf("unexpected addresses %v", addrs)
	}
	if got := server.queriesForA(); got != 2 {
		t.Fatalf("expected the A query to be sent twice, got %d", got)
	}
	// Go's resolver would otherwise wait the resolv.conf timeout, 5 s by default.
	if elapsed < 150*time.Millisecond || elapsed > 2*time.Second {
		t.Fatalf("lookup took %s, want about the 200ms query timeout", elapsed)
	}
}

func TestQuickRetryResolverHearsASlowServerOnceQueriesGoUnanswered(t *testing.T) {
	t.Parallel()

	server := startDNSServer(t, 300*time.Millisecond)
	resolver := newQuickRetryResolver(100*time.Millisecond, 500*time.Millisecond, []string{server.conn.LocalAddr().String()})

	// Like downloadS3ObjectToFileWithRetry: look up again after a failure.
	start := time.Now()
	for {
		addrs, err := resolver.LookupHost(context.Background(), "bucket.s3.us-east-1.amazonaws.com")
		if err == nil {
			if len(addrs) != 1 || addrs[0] != "192.0.2.1" {
				t.Fatalf("unexpected addresses %v", addrs)
			}
			break
		}
		if time.Since(start) > 10*time.Second {
			t.Fatalf("a server answering in 300ms was never heard: %v", err)
		}
		time.Sleep(50 * time.Millisecond)
	}
	// The limit applied first: queries were cut off for the window.
	if elapsed := time.Since(start); elapsed < 600*time.Millisecond {
		t.Fatalf("answered after %s, before the window ended", elapsed)
	}
	if got := server.queriesForA(); got < 2 {
		t.Fatalf("expected earlier A queries to time out, got %d", got)
	}
}

func TestQuickRetryResolverBoundsTheTCPDial(t *testing.T) {
	t.Parallel()

	// 192.0.2.1 (TEST-NET-1) is not routed: a TCP connection to it hangs
	// until the dial gives up, unless the network refuses it at once.
	resolver := newQuickRetryResolver(200*time.Millisecond, time.Minute, []string{"192.0.2.1:53"})
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	start := time.Now()
	conn, err := resolver.Dial(ctx, "tcp", "127.0.0.53:53")
	if err == nil {
		_ = conn.Close()
		t.Skip("192.0.2.1:53 accepted a connection on this network")
	}
	if elapsed := time.Since(start); elapsed > 2*time.Second {
		t.Fatalf("the TCP dial took %s, want about the 200ms query timeout", elapsed)
	}
}

func TestQuickRetryLiftsTheLimitAfterTheWindow(t *testing.T) {
	t.Parallel()

	timeout := &net.OpError{Op: "read", Err: os.ErrDeadlineExceeded}
	q := &quickRetry{limit: 100 * time.Millisecond, window: 50 * time.Millisecond}

	q.observe(timeout)
	time.Sleep(60 * time.Millisecond)
	q.observe(nil)
	q.observe(timeout)
	if got := q.currentLimit(); got != 100*time.Millisecond {
		t.Fatalf("an answer should start a new run of timeouts, limit %s", got)
	}
	time.Sleep(60 * time.Millisecond)
	q.observe(timeout)
	if got := q.currentLimit(); got != 0 {
		t.Fatalf("timeouts lasting the window should lift the limit, limit %s", got)
	}
	q.observe(nil)
	if got := q.currentLimit(); got != 0 {
		t.Fatalf("the limit should stay lifted after an answer, limit %s", got)
	}
}

func TestUpstreamNameserversReadsResolvedUpstreamConfig(t *testing.T) {
	t.Parallel()

	path := filepath.Join(t.TempDir(), "resolv.conf")
	content := "# This is /run/systemd/resolve/resolv.conf managed by man:systemd-resolved(8).\n" +
		"nameserver 10.1.0.2\nnameserver fd00:ec2::253\nsearch ec2.internal\n"
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	got := upstreamNameservers(path)
	want := []string{"10.1.0.2:53", "[fd00:ec2::253]:53"}
	if len(got) != len(want) || got[0] != want[0] || got[1] != want[1] {
		t.Fatalf("got %v, want %v", got, want)
	}
	if got := upstreamNameservers(filepath.Join(t.TempDir(), "missing")); got != nil {
		t.Fatalf("a missing file should return no servers, got %v", got)
	}
}

func TestCapDeadline(t *testing.T) {
	t.Parallel()

	now := time.Now()
	if got := capDeadline(time.Time{}, time.Second); got.Before(now) || got.After(now.Add(2*time.Second)) {
		t.Fatalf("no deadline should become the limit, got %s", got.Sub(now))
	}
	if got := capDeadline(now.Add(5*time.Second), time.Second); got.After(now.Add(2 * time.Second)) {
		t.Fatalf("a later deadline should be capped, got %s", got.Sub(now))
	}
	if early := now.Add(100 * time.Millisecond); !capDeadline(early, time.Second).Equal(early) {
		t.Fatal("an earlier deadline should be kept")
	}
	if late := now.Add(5 * time.Second); !capDeadline(late, 0).Equal(late) {
		t.Fatal("no limit should keep the resolver's deadline")
	}
}
