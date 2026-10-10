package torrent

import (
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"
)

// Exercise the scraper-to-HTTP path rather than only the query encoder.
// PublicIp can be auto-detected for peer/DHT use; tracker IP overrides must be
// explicit so a different HTTP route or VPN change cannot advertise a stale IP.
func TestMumpaScraperAnnounceOverrideIsExplicit(t *testing.T) {
	queries := make(chan url.Values, 4)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		queries <- r.URL.Query()
		w.Header().Set("Content-Type", "text/plain")
		w.Write([]byte("d8:intervali60e5:peers0:e"))
	}))
	defer server.Close()
	cl, tor, _, _ := mumpaOutgoingFixture(t, false)
	cl.config.PublicIp4 = net.ParseIP("192.0.2.20")
	cl.config.PublicIp6 = net.ParseIP("2001:db8::20")
	u, _ := url.Parse(server.URL + "/announce?fixture_token=original")
	scraper := trackerScraper{u: *u, t: tor}
	if result := scraper.announce(); result.Err != nil {
		t.Fatal(result.Err)
	}
	q := <-queries
	for _, key := range []string{"ip", "ipv4", "ipv6"} {
		if q.Has(key) {
			t.Fatalf("auto-detected public IP produced tracker override %s", key)
		}
	}
	if !cl.config.PublicIp4.Equal(net.ParseIP("192.0.2.20")) || !cl.config.PublicIp6.Equal(net.ParseIP("2001:db8::20")) {
		t.Fatal("tracker announce changed the public peer/DHT addresses")
	}
	// Deliberate configured overrides keep their original semantics.
	cl.config.AnnounceIp4 = net.ParseIP("192.0.2.30")
	cl.config.AnnounceIp6 = net.ParseIP("2001:db8::30")
	if result := scraper.announce(); result.Err != nil {
		t.Fatal(result.Err)
	}
	q = <-queries
	if q.Get("ipv4") != "192.0.2.30" || q.Get("ipv6") != "2001:db8::30" {
		t.Fatal("explicit tracker IP overrides were not preserved")
	}
	if q.Get("port") != "42000" || q.Get("fixture_token") != "original" {
		t.Fatal("explicit override changed announce port or original query")
	}
	values := q["ip"]
	if len(values) != 2 || values[0] != "192.0.2.30" || values[1] != "2001:db8::30" {
		t.Fatalf("explicit ip values = %v", values)
	}
}
