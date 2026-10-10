package tracker

import (
	"context"
	"encoding/binary"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"sync/atomic"
	"testing"
	"time"

	"github.com/anacrolix/dht/v2/krpc"
)

func sourceAnnounce(target string) Announce {
	request := AnnounceRequest{Port: 42001, NumWant: -1, Event: Started}
	copy(request.InfoHash[:], "local-infohash-tests!")
	copy(request.PeerId[:], "-MumpaTest-0000000001")
	return Announce{TrackerUrl: target, Request: request, SourceIP: net.ParseIP("127.0.0.2")}
}

func TestMumpaTrackerHTTPSourceBinding(t *testing.T) {
	for _, override := range []bool{false, true} {
		t.Run(map[bool]string{false: "no-public-override", true: "explicit-public-override"}[override], func(t *testing.T) {
			observed := make(chan bool, 1)
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				host, _, _ := net.SplitHostPort(r.RemoteAddr)
				query := r.URL.Query()
				validQuery := !query.Has("ip") && !query.Has("ipv4") && !query.Has("ipv6")
				if override {
					validQuery = query.Get("ip") == "203.0.113.11" && query.Get("ipv4") == "203.0.113.11"
				}
				observed <- net.ParseIP(host).Equal(net.ParseIP("127.0.0.2")) && validQuery && query.Get("port") == "42001"
				w.Write([]byte("d8:intervali60e5:peers0:e"))
			}))
			defer server.Close()
			opt := sourceAnnounce(server.URL + "/announce")
			if override {
				opt.ClientIp4 = krpc.NodeAddr{IP: net.ParseIP("203.0.113.11"), Port: 42200}
			}
			ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
			defer cancel()
			opt.Context = ctx
			if _, err := opt.Do(); err != nil {
				t.Fatal(err)
			}
			if !<-observed {
				t.Fatal("HTTP source binding changed source or announce parameters")
			}
		})
	}
}

func TestMumpaTrackerHTTPSRedirectPreservesSource(t *testing.T) {
	observed := make(chan bool, 2)
	checkSource := func(r *http.Request) {
		host, _, _ := net.SplitHostPort(r.RemoteAddr)
		observed <- net.ParseIP(host).Equal(net.ParseIP("127.0.0.2"))
	}
	secure := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		checkSource(r)
		w.Write([]byte("d8:intervali60e5:peers0:e"))
	}))
	defer secure.Close()
	redirect := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		checkSource(r)
		http.Redirect(w, r, secure.URL+"/announce?"+r.URL.RawQuery, http.StatusTemporaryRedirect)
	}))
	defer redirect.Close()
	opt := sourceAnnounce(redirect.URL + "/announce")
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	opt.Context = ctx
	if _, err := opt.Do(); err != nil {
		t.Fatal(err)
	}
	if !<-observed || !<-observed {
		t.Fatal("HTTP/HTTPS redirect changed bound source")
	}
}

func TestMumpaTrackerSourceBindingFailsClosed(t *testing.T) {
	var requests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		w.Write([]byte("d8:intervali60e5:peers0:e"))
	}))
	defer server.Close()
	for _, kind := range []string{"invalid", "unavailable", "proxy"} {
		t.Run(kind, func(t *testing.T) {
			opt := sourceAnnounce(server.URL + "/announce")
			if kind == "invalid" {
				opt.SourceIP = net.IP{127}
			}
			if kind == "unavailable" {
				opt.SourceIP = net.ParseIP("192.0.2.254")
			}
			if kind == "proxy" {
				opt.HTTPProxy = func(*http.Request) (*url.URL, error) { t.Error("proxy callback executed"); return nil, nil }
			}
			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			defer cancel()
			opt.Context = ctx
			if _, err := opt.Do(); err == nil {
				t.Fatal("invalid source configuration succeeded")
			}
			if requests.Load() != 0 {
				t.Fatal("binding failure fell back to an unbound request")
			}
		})
	}
}

func TestMumpaTrackerUDPSourceBinding(t *testing.T) {
	for _, override := range []bool{false, true} {
		t.Run(map[bool]string{false: "no-public-override", true: "explicit-public-override"}[override], func(t *testing.T) {
			server, err := net.ListenPacket("udp4", "127.0.0.1:0")
			if err != nil {
				t.Fatal(err)
			}
			defer server.Close()
			observed := make(chan bool, 1)
			go func() {
				buffer := make([]byte, 2048)
				valid := true
				for round := 0; round < 2; round++ {
					server.SetReadDeadline(time.Now().Add(2 * time.Second))
					n, remote, err := server.ReadFrom(buffer)
					if err != nil || n < 16 {
						observed <- false
						return
					}
					valid = valid && remote.(*net.UDPAddr).IP.Equal(net.ParseIP("127.0.0.2"))
					action := binary.BigEndian.Uint32(buffer[8:12])
					transaction := binary.BigEndian.Uint32(buffer[12:16])
					response := make([]byte, 16)
					if round == 1 {
						response = make([]byte, 20)
					}
					binary.BigEndian.PutUint32(response[0:4], action)
					binary.BigEndian.PutUint32(response[4:8], transaction)
					if round == 0 {
						valid = valid && action == uint32(ActionConnect)
						binary.BigEndian.PutUint64(response[8:16], 12345)
					} else {
						valid = valid && action == uint32(ActionAnnounce) && n >= 98
						if n >= 98 {
							wantIP := uint32(0)
							if override {
								wantIP = binary.BigEndian.Uint32(net.ParseIP("203.0.113.11").To4())
							}
							valid = valid && binary.BigEndian.Uint32(buffer[84:88]) == wantIP && binary.BigEndian.Uint16(buffer[96:98]) == 42001
						}
						binary.BigEndian.PutUint32(response[8:12], 60)
					}
					if _, err = server.WriteTo(response, remote); err != nil {
						observed <- false
						return
					}
				}
				observed <- valid
			}()
			opt := sourceAnnounce("udp://" + server.LocalAddr().String() + "/announce")
			if override {
				opt.ClientIp4 = krpc.NodeAddr{IP: net.ParseIP("203.0.113.11")}
			}
			ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
			defer cancel()
			opt.Context = ctx
			if _, err := opt.Do(); err != nil {
				t.Fatal(err)
			}
			if !<-observed {
				t.Fatal("UDP tracker source or public override changed")
			}
		})
	}
}

func TestMumpaTrackerBoundDialRejectsWrongFamily(t *testing.T) {
	opt := sourceAnnounce("udp://127.0.0.1:1/announce")
	if _, err := opt.dialBound(context.Background(), "udp6", "[::1]:1"); err == nil {
		t.Fatal("source silently changed network family")
	}
}
