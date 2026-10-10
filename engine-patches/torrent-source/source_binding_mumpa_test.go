package torrent

import (
	"context"
	"net"
	"net/http"
	"net/url"
	"testing"
	"time"

	"github.com/anacrolix/dht/v2"
	"github.com/anacrolix/dht/v2/krpc"
	"github.com/anacrolix/missinggo"
)

func TestMumpaPeerSocketSourceBinding(t *testing.T) {
	for _, tc := range []struct{ name, listenHost, wantSource string }{
		{"explicit", "127.0.0.2", "127.0.0.2"},
		{"system-default", "0.0.0.0", "127.0.0.1"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			peer, err := net.Listen("tcp4", "127.0.0.1:0")
			if err != nil {
				t.Fatal(err)
			}
			defer peer.Close()
			observed := make(chan net.IP, 1)
			go func() {
				conn, err := peer.Accept()
				if err != nil {
					return
				}
				observed <- conn.RemoteAddr().(*net.TCPAddr).IP
				conn.Close()
			}()
			source, err := listenTcp("tcp4", net.JoinHostPort(tc.listenHost, "0"), "")
			if err != nil {
				t.Fatal(err)
			}
			defer source.Close()
			ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
			defer cancel()
			conn, err := source.dial(ctx, peer.Addr().String())
			if err != nil {
				t.Fatal(err)
			}
			conn.Close()
			select {
			case ip := <-observed:
				if !ip.Equal(net.ParseIP(tc.wantSource)) {
					t.Fatal("peer observed wrong source")
				}
			case <-ctx.Done():
				t.Fatal("peer did not accept local connection")
			}
		})
	}
}

func TestMumpaClientSourceBindingRejectsProxy(t *testing.T) {
	for _, kind := range []string{"peer-proxy", "http-proxy"} {
		t.Run(kind, func(t *testing.T) {
			cfg := NewDefaultClientConfig()
			cfg.SetListenAddr("127.0.0.2:0")
			cfg.DisableIPv6, cfg.DisableUTP, cfg.NoDHT = true, true, true
			cfg.NoDefaultPortForwarding = true
			if kind == "peer-proxy" {
				cfg.ProxyURL = "socks5://127.0.0.1:1"
			} else {
				cfg.HTTPProxy = func(*http.Request) (*url.URL, error) {
					t.Error("proxy callback must not run for rejected configuration")
					return nil, nil
				}
			}
			client, err := NewClient(cfg)
			if err == nil {
				if client != nil {
					client.Close()
				}
				t.Fatal("source plus proxy accepted")
			}
			if client != nil {
				t.Fatal("failed source binding returned a live client")
			}
		})
	}
}

func TestMumpaSourceBindingValidation(t *testing.T) {
	for _, tc := range []struct {
		host, network string
		wantError     bool
		wantIP        string
	}{
		{"", "tcp4", false, ""},
		{"0.0.0.0", "udp4", false, ""},
		{"::", "tcp6", false, ""},
		{"127.0.0.2", "tcp4", false, "127.0.0.2"},
		{"127.0.0.2", "udp4", false, "127.0.0.2"},
		{"127.0.0.2", "tcp6", true, ""},
		{"::1", "udp4", true, ""},
		{"invalid-source.invalid", "tcp4", true, ""},
	} {
		cfg := NewDefaultClientConfig()
		cfg.ListenHost = func(string) string { return tc.host }
		ip, err := outgoingSourceIP(cfg, tc.network)
		if (err != nil) != tc.wantError {
			t.Fatal("source validation result differs")
		}
		if !tc.wantError && !ip.Equal(net.ParseIP(tc.wantIP)) {
			t.Fatal("source validation returned wrong IP")
		}
	}
}

func TestMumpaPeerSourceBindingUnavailableDoesNotListenUnbound(t *testing.T) {
	source, err := listenTcp("tcp4", "192.0.2.254:0", "")
	if err == nil {
		if source != nil {
			source.Close()
		}
		t.Fatal("unavailable source unexpectedly listened")
	}
	if source != nil {
		t.Fatal("binding failure returned fallback socket")
	}
}

func TestMumpaUTPAndDHTShareBoundPacketSource(t *testing.T) {
	// The actual uTP transport and DHT server share this PacketConn in NewClient.
	// Every address and starting node in this test is local; no bootstrap routers
	// or real infohashes are involved.
	source, err := NewUtpSocket("udp4", "127.0.0.2:0", nil)
	if err != nil {
		t.Fatal(err)
	}
	defer source.Close()
	peer, err := NewUtpSocket("udp4", "127.0.0.1:0", nil)
	if err != nil {
		t.Fatal(err)
	}
	defer peer.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
	defer cancel()
	observedUTP := make(chan net.IP, 1)
	go func() {
		conn, err := peer.Accept()
		if err != nil {
			return
		}
		observedUTP <- missinggo.AddrIP(conn.RemoteAddr())
		conn.Close()
	}()
	conn, err := source.DialContext(ctx, "udp4", peer.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	conn.Close()
	select {
	case ip := <-observedUTP:
		if !ip.Equal(net.ParseIP("127.0.0.2")) {
			t.Fatal("uTP peer observed wrong source")
		}
	case <-ctx.Done():
		t.Fatal("uTP peer did not accept local connection")
	}
	emptyStartingNodes := func() ([]dht.Addr, error) { return nil, nil }
	observedDHT := make(chan net.IP, 1)
	peerDHT, err := dht.NewServer(&dht.ServerConfig{
		Conn: peer, StartingNodes: emptyStartingNodes, NoSecurity: true,
		OnQuery: func(_ *krpc.Msg, addr net.Addr) bool {
			select {
			case observedDHT <- missinggo.AddrIP(addr):
			default:
			}
			return true
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	defer peerDHT.Close()
	sourceDHT, err := dht.NewServer(&dht.ServerConfig{
		Conn: source, StartingNodes: emptyStartingNodes, NoSecurity: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer sourceDHT.Close()
	result := sourceDHT.Query(ctx, dht.NewAddr(peer.LocalAddr()), "ping", dht.QueryInput{NumTries: 1})
	if err := result.ToError(); err != nil {
		t.Fatal(err)
	}
	select {
	case ip := <-observedDHT:
		if !ip.Equal(net.ParseIP("127.0.0.2")) {
			t.Fatal("DHT peer observed wrong source")
		}
	case <-ctx.Done():
		t.Fatal("DHT peer did not receive local query")
	}
}

func TestMumpaTrackerAddressSelectionMatchesSourceFamily(t *testing.T) {
	ip4, ip6 := net.ParseIP("127.0.0.1"), net.ParseIP("::1")
	for _, tc := range []struct {
		name, host, scheme string
		candidates         []net.IP
		want               net.IP
	}{
		{"bound4-skips-first-IPv6", "127.0.0.2", "http", []net.IP{ip6, ip4}, ip4},
		{"bound4-UDP-skips-first-IPv6", "127.0.0.2", "udp", []net.IP{ip6, ip4}, ip4},
		{"bound6-skips-first-IPv4", "::1", "https", []net.IP{ip4, ip6}, ip6},
		{"bound6-UDP-skips-first-IPv4", "::1", "udp", []net.IP{ip4, ip6}, ip6},
		{"bound4-udp6-unavailable", "127.0.0.2", "udp6", []net.IP{ip6, ip4}, nil},
		{"bound6-udp4-unavailable", "::1", "udp4", []net.IP{ip4, ip6}, nil},
		{"bound6-no-IPv4-fallback", "::1", "http", []net.IP{ip4}, nil},
		{"bound4-no-IPv6-fallback", "127.0.0.2", "http", []net.IP{ip6}, nil},
		{"default-keeps-first-IPv6", "", "http", []net.IP{ip6, ip4}, ip6},
		{"wildcard4-keeps-first-IPv6", "0.0.0.0", "http", []net.IP{ip6, ip4}, ip6},
		{"wildcard6-keeps-first-IPv4", "::", "http", []net.IP{ip4, ip6}, ip4},
		{"default-udp4-skips-IPv6", "", "udp4", []net.IP{ip6, ip4}, ip4},
		{"default-udp6-skips-IPv4", "", "udp6", []net.IP{ip4, ip6}, ip6},
		{"empty-result", "", "http", nil, nil},
	} {
		t.Run(tc.name, func(t *testing.T) {
			cfg := NewDefaultClientConfig()
			cfg.ListenHost = func(string) string { return tc.host }
			scraper := trackerScraper{
				u: url.URL{Scheme: tc.scheme},
				t: &Torrent{cl: &Client{config: cfg}},
			}
			// Exercise pure selection; no DNS lookup, sockets, or real trackers.
			ip, err := scraper.getIpFrom(tc.candidates)
			if tc.want == nil {
				if err == nil || ip != nil {
					t.Fatal("incompatible candidates unexpectedly selected an address")
				}
				return
			}
			if err != nil || !ip.Equal(tc.want) {
				t.Fatal("tracker did not select the expected compatible candidate")
			}
		})
	}
}
