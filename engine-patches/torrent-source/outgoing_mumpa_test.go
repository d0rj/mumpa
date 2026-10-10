package torrent

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/anacrolix/log"
	"github.com/anacrolix/torrent/metainfo"
	"github.com/anacrolix/torrent/mse"
	pp "github.com/anacrolix/torrent/peer_protocol"
)

// Pipes exercise the actual initiator and policy without OS sockets, DHT,
// trackers, or the reverse inbound connection used by the app's media fixture.
type mumpaHandshakeSocket struct {
	mu      sync.Mutex
	dials   int
	conns   []net.Conn
	results chan error
	peer    func(int, net.Conn) error
}

type mumpaObservedConn struct {
	net.Conn
	closed atomic.Bool
}

func (c *mumpaObservedConn) Close() error {
	c.closed.Store(true)
	return c.Conn.Close()
}

func (s *mumpaHandshakeSocket) Addr() net.Addr {
	return &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 42000}
}
func (s *mumpaHandshakeSocket) Accept() (net.Conn, error) { return nil, net.ErrClosed }
func (s *mumpaHandshakeSocket) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, c := range s.conns {
		c.Close()
	}
	return nil
}
func (s *mumpaHandshakeSocket) dial(ctx context.Context, _ string) (net.Conn, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	pipe, remote := net.Pipe()
	local := &mumpaObservedConn{Conn: pipe}
	s.mu.Lock()
	if s.dials != 0 && !s.conns[2*(s.dials-1)].(*mumpaObservedConn).closed.Load() {
		s.mu.Unlock()
		local.Close()
		remote.Close()
		return nil, errors.New("fallback started before closing the previous attempt")
	}
	s.dials++
	n := s.dials
	s.conns = append(s.conns, local, remote)
	s.mu.Unlock()
	go func() {
		defer remote.Close()
		remote.SetDeadline(time.Now().Add(3 * time.Second))
		s.results <- s.peer(n, remote)
	}()
	return local, nil
}
func (s *mumpaHandshakeSocket) check(t *testing.T, want int) {
	t.Helper()
	s.mu.Lock()
	n := s.dials
	s.mu.Unlock()
	if n != want {
		t.Fatalf("dials = %d, want %d", n, want)
	}
	s.mu.Lock()
	for i := 0; i < n; i++ {
		if !s.conns[2*i].(*mumpaObservedConn).closed.Load() {
			s.mu.Unlock()
			t.Fatalf("outgoing attempt %d did not close its own connection", i+1)
		}
	}
	s.mu.Unlock()
	for i := 0; i < want; i++ {
		select {
		case err := <-s.results:
			if err != nil {
				t.Fatal(err)
			}
		case <-time.After(time.Second):
			t.Fatal("peer pipe did not finish; connection leaked")
		}
	}
}

func mumpaOutgoingFixture(t *testing.T, force bool) (*Client, *Torrent, *mumpaHandshakeSocket, IpPort) {
	t.Helper()
	cfg := NewDefaultClientConfig()
	cfg.ForceEncryption = force
	cfg.NoDHT = true
	cfg.DisableTrackers = true
	cfg.DisableUTP = true
	cfg.NominalDialTimeout = 2 * time.Second
	cfg.MinDialTimeout = cfg.NominalDialTimeout
	cfg.HandshakesTimeout = 500 * time.Millisecond
	s := &mumpaHandshakeSocket{results: make(chan error, 4)}
	cl := &Client{config: cfg, conns: []socket{s}, extensionBytes: defaultPeerExtensionBytes(), logger: log.Default.FilterLevel(log.Error)}
	copy(cl.peerID[:], "-MP0002-local-fixture")
	tor := cl.newTorrent(metainfo.HashBytes([]byte("original-mumpa-handshake-test")), nil)
	t.Cleanup(func() { s.Close() })
	return cl, tor, s, IpPort{IP: net.IPv4(127, 0, 0, 1), Port: 42001}
}

func mumpaReadMSE(c net.Conn) error {
	var key [96]byte
	if _, err := io.ReadFull(c, key[:]); err != nil {
		return fmt.Errorf("read initiator MSE key: %w", err)
	}
	if string(key[:len(pp.Protocol)]) == pp.Protocol {
		return errors.New("first initiator attempt unexpectedly used plaintext")
	}
	return nil
}

func mumpaPlaintextPeer(c net.Conn, ih metainfo.Hash) error {
	var request [68]byte
	if _, err := io.ReadFull(c, request[:]); err != nil {
		return fmt.Errorf("read plaintext handshake: %w", err)
	}
	if string(request[:20]) != pp.Protocol || string(request[28:48]) != string(ih[:]) {
		return errors.New("fallback did not send the expected plaintext torrent handshake")
	}
	copy(request[48:], "-MP0002-remote-peer!!")
	if _, err := c.Write(request[:]); err != nil {
		return err
	}
	_, err := io.Copy(io.Discard, c)
	return err
}

func TestMumpaOutgoingMSEErrorFallsBackToPlaintext(t *testing.T) {
	cl, tor, s, addr := mumpaOutgoingFixture(t, false)
	s.peer = func(n int, c net.Conn) error {
		switch n {
		case 1:
			// A real plaintext-only peer closes on the encrypted DH header.
			// InitiateHandshake returns a non-nil error reading its remote key.
			return mumpaReadMSE(c)
		case 2:
			return mumpaPlaintextPeer(c, tor.infoHash)
		default:
			return errors.New("more than two outgoing attempts")
		}
	}
	c, err := cl.establishOutgoingConn(tor, addr)
	if err != nil || c == nil {
		t.Fatalf("optional-encryption connection = %v, error = %v", c, err)
	}
	if c.headerEncrypted {
		t.Fatal("fallback connection still has an encrypted header")
	}
	c.conn.Close()
	s.check(t, 2)
}

func TestMumpaOutgoingForceEncryptionNeverFallsBack(t *testing.T) {
	cl, tor, s, addr := mumpaOutgoingFixture(t, true)
	s.peer = func(n int, c net.Conn) error {
		if n != 1 {
			return errors.New("ForceEncryption dialed a plaintext fallback")
		}
		return mumpaReadMSE(c)
	}
	c, err := cl.establishOutgoingConn(tor, addr)
	if err == nil || c != nil {
		t.Fatalf("forced-encryption rejection = %v, error = %v", c, err)
	}
	s.check(t, 1)
}

func TestMumpaOutgoingCancellationNeverFallsBack(t *testing.T) {
	cl, tor, s, addr := mumpaOutgoingFixture(t, false)
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	s.peer = func(n int, c net.Conn) error {
		if n != 1 {
			return errors.New("canceled connection dialed a fallback")
		}
		if err := mumpaReadMSE(c); err != nil {
			return err
		}
		cancel()
		// Close makes the first MSE handshake fail after its context is canceled.
		return nil
	}
	c, err := cl.establishOutgoingConnWithContext(ctx, tor, addr)
	if !errors.Is(err, context.Canceled) || c != nil {
		t.Fatalf("canceled connection = %v, error = %v", c, err)
	}
	s.check(t, 1)
	// No half-open writer/socket survives the first attempt's deferred Close.
	s.mu.Lock()
	first := s.conns[0]
	s.mu.Unlock()
	if _, err := first.Write([]byte{1}); !errors.Is(err, io.ErrClosedPipe) {
		t.Fatalf("canceled pipe is not closed: %v", err)
	}
}

func TestMumpaOutgoingDeadlineNeverFallsBack(t *testing.T) {
	cl, tor, s, addr := mumpaOutgoingFixture(t, false)
	cl.config.NominalDialTimeout = 150 * time.Millisecond
	cl.config.MinDialTimeout = cl.config.NominalDialTimeout
	s.peer = func(n int, c net.Conn) error {
		if n != 1 {
			return errors.New("expired connection dialed a fallback")
		}
		if err := mumpaReadMSE(c); err != nil {
			return err
		}
		// Do not answer the key: the actual attempt's deadline must wake it.
		_, err := io.Copy(io.Discard, c)
		return err
	}
	c, err := cl.establishOutgoingConn(tor, addr)
	if !errors.Is(err, context.DeadlineExceeded) || c != nil {
		t.Fatalf("expired connection = %v, error = %v", c, err)
	}
	s.check(t, 1)
}

func TestMumpaOutgoingSupportedMSEKeepsEncryption(t *testing.T) {
	cl, tor, s, addr := mumpaOutgoingFixture(t, true)
	s.peer = func(n int, c net.Conn) error {
		if n != 1 {
			return errors.New("successful MSE unexpectedly opened a fallback")
		}
		rw, method, err := mse.ReceiveHandshake(c, func(f func([]byte) bool) { f(tor.infoHash[:]) }, func(mse.CryptoMethod) mse.CryptoMethod { return mse.CryptoMethodRC4 })
		if err != nil {
			return err
		}
		if method != mse.CryptoMethodRC4 {
			return errors.New("forced MSE negotiated another crypto method")
		}
		var remoteID [20]byte
		copy(remoteID[:], "-MP0002-remote-peer!!")
		_, ok, err := pp.Handshake(rw, &tor.infoHash, remoteID, defaultPeerExtensionBytes())
		if !ok || err != nil {
			return fmt.Errorf("remote encrypted BT handshake: ok=%v error=%v", ok, err)
		}
		_, err = io.Copy(io.Discard, c)
		return err
	}
	c, err := cl.establishOutgoingConn(tor, addr)
	if err != nil || c == nil {
		t.Fatalf("MSE connection = %v, error = %v", c, err)
	}
	if !c.headerEncrypted || c.cryptoMethod != mse.CryptoMethodRC4 {
		t.Fatal("supported forced MSE was downgraded")
	}
	c.conn.Close()
	s.check(t, 1)
}
