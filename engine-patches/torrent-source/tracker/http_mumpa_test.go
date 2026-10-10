package tracker

import (
	"net"
	"net/url"
	"strings"
	"testing"

	"github.com/anacrolix/dht/v2/krpc"
)

func TestMumpaAnnounceBareIP(t *testing.T) {
	for _, tc := range []struct {
		name string
		ip   string
		key  string
		port int
	}{
		{"ipv4-zero-port", "192.0.2.11", "ipv4", 0},
		{"ipv4-node-port", "192.0.2.11", "ipv4", 42000},
		{"ipv6-zero-port", "2001:db8::11", "ipv6", 0},
		{"ipv6-node-port", "2001:db8::11", "ipv6", 42000},
	} {
		t.Run(tc.name, func(t *testing.T) {
			u, _ := url.Parse("https://example.invalid/announce?fixture_token=original")
			opts := Announce{}
			addr := krpc.NodeAddr{IP: net.ParseIP(tc.ip), Port: tc.port}
			if tc.key == "ipv4" {
				opts.ClientIp4 = addr
			} else {
				opts.ClientIp6 = addr
			}
			setAnnounceParams(u, &AnnounceRequest{Port: 42001}, opts)
			q := u.Query()
			if q.Get("ip") != tc.ip || q.Get(tc.key) != tc.ip {
				t.Fatalf("announce IP is not a bare address: ip=%q %s=%q", q.Get("ip"), tc.key, q.Get(tc.key))
			}
			if q.Get("port") != "42001" {
				t.Fatal("IP override changed the independent listening port")
			}
			if !strings.HasPrefix(u.RawQuery, "fixture_token=original&") {
				t.Fatal("original private-tracker query no longer comes first")
			}
		})
	}
}

func TestMumpaAnnounceNoAutomaticIPOverride(t *testing.T) {
	u, _ := url.Parse("https://example.invalid/announce")
	setAnnounceParams(u, &AnnounceRequest{Port: 42001}, Announce{})
	q := u.Query()
	for _, key := range []string{"ip", "ipv4", "ipv6"} {
		if q.Has(key) {
			t.Fatalf("absent override produced %s", key)
		}
	}
}
