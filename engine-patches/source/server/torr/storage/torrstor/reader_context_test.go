package torrstor

import (
	"context"
	"crypto/sha1"
	"errors"
	"testing"
	"time"

	"server/settings"

	"github.com/anacrolix/torrent"
	"github.com/anacrolix/torrent/bencode"
	"github.com/anacrolix/torrent/metainfo"
)

// No sockets, trackers, DHT or peers: metadata exists, but its original audio
// piece is absent. Exercise the actual pinned torrent reader's blocked read.
func TestReaderContextCancellationReleasesPeerlessCache(t *testing.T) {
	previousSettings := settings.BTsets
	settings.BTsets = &settings.BTSets{ReaderReadAHead: 95, ConnectionsLimit: 4}
	t.Cleanup(func() { settings.BTsets = previousSettings })
	store := NewStorage(65536)
	cfg := torrent.NewDefaultClientConfig()
	cfg.DataDir = t.TempDir()
	cfg.DefaultStorage = store
	cfg.DisableTCP = true
	cfg.DisableUTP = true
	cfg.NoDHT = true
	cfg.DisableTrackers = true
	cfg.DisablePEX = true
	cfg.NoDefaultPortForwarding = true
	cfg.NoUpload = true
	client, err := torrent.NewClient(cfg)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { client.Close() })
	digest := sha1.Sum([]byte("original uncached audio"))
	infoBytes, err := bencode.Marshal(metainfo.Info{
		Name: "original.wav", PieceLength: 16384,
		Length: int64(len("original uncached audio")), Pieces: digest[:],
	})
	if err != nil {
		t.Fatal(err)
	}
	tor, _, err := client.AddTorrentSpec(&torrent.TorrentSpec{
		InfoHash: metainfo.HashBytes(infoBytes), InfoBytes: infoBytes,
	})
	if err != nil {
		t.Fatal(err)
	}
	cache := store.GetCache(tor.InfoHash())
	cache.SetTorrent(tor)
	for attempt := 0; attempt < 3; attempt++ {
		reader := cache.NewReader(tor.Files()[0])
		ctx, cancel := context.WithCancel(context.Background())
		done := make(chan error, 1)
		go func() {
			_, err := reader.ReadContext(ctx, make([]byte, 4096))
			done <- err
		}()
		select {
		case err := <-done:
			cancel()
			cache.CloseReader(reader)
			t.Fatalf("missing piece read unexpectedly completed: %v", err)
		case <-time.After(50 * time.Millisecond):
		}
		reader.mu.Lock()
		inFlight, inUse := reader.inFlight, reader.isUse
		reader.mu.Unlock()
		if inFlight != 1 || !inUse || cache.Readers() != 1 {
			cancel()
			<-done
			cache.CloseReader(reader)
			t.Fatalf("attempt %d: blocking read bypassed cache bookkeeping: inFlight=%d inUse=%v", attempt, inFlight, inUse)
		}
		cancel()
		select {
		case err := <-done:
			if !errors.Is(err, context.Canceled) {
				cache.CloseReader(reader)
				t.Fatalf("attempt %d: cancellation returned %v", attempt, err)
			}
		case <-time.After(2 * time.Second):
			// Dropping is only emergency cleanup after a failed assertion; the
			// passing path never drops metadata or stops the client between reads.
			tor.Drop()
			<-done
			cache.CloseReader(reader)
			t.Fatalf("attempt %d: ReadContext ignored cancellation", attempt)
		}
		if reader.inFlight != 0 {
			t.Fatalf("attempt %d: read left %d operations in flight", attempt, reader.inFlight)
		}
		cache.CloseReader(reader)
		if count := cache.Readers(); count != 0 {
			t.Fatalf("attempt %d: cache retained %d readers", attempt, count)
		}
	}
}
