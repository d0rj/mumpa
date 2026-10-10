package torr

import (
	"testing"

	"github.com/anacrolix/torrent"
)

func TestMumpaListenSourceAddressFamily(t *testing.T) {
	for _, test := range []struct {
		name, address   string
		bound, no4, no6 bool
	}{
		{"system-ipv4", "0.0.0.0:12345", false, false, false},
		{"system-ipv6", "[::]:12345", false, false, false},
		{"explicit-ipv4", "192.0.2.10:12345", true, false, true},
		{"explicit-ipv6", "[2001:db8::10]:12345", true, true, false},
	} {
		t.Run(test.name, func(t *testing.T) {
			config := torrent.NewDefaultClientConfig()
			config.DisableIPv4 = false
			config.DisableIPv6 = false
			config.SetListenAddr(test.address)
			bound := configureListenSource(config)
			if bound != test.bound || config.DisableIPv4 != test.no4 || config.DisableIPv6 != test.no6 {
				t.Fatalf("binding=%v disabled4=%v disabled6=%v", bound, config.DisableIPv4, config.DisableIPv6)
			}
			if config.ListenPort != 12345 {
				t.Fatal("peer port changed")
			}
		})
	}
}
