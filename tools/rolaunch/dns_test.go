package main

import (
	"context"
	"encoding/binary"
	"net"
	"sync"
	"testing"
	"time"
)

// A DNS server that ignores the first A query and answers every later one,
// like the unanswered query seen a few seconds into boot.
type lossyDNSServer struct {
	conn     *net.UDPConn
	mu       sync.Mutex
	aQueries int
}

func startLossyDNSServer(t *testing.T) *lossyDNSServer {
	t.Helper()
	conn, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	t.Cleanup(func() { _ = conn.Close() })
	s := &lossyDNSServer{conn: conn}
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
			if first {
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
	resolver := newQuickRetryResolver(200*time.Millisecond, server.conn.LocalAddr().String())

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
}
