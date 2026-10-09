package torr

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

type missingPieceReader struct {
	started chan struct{}
	stop    <-chan struct{}
	once    sync.Once
	pos     int64
}

func (r *missingPieceReader) ReadContext(ctx context.Context, p []byte) (int, error) {
	r.once.Do(func() { close(r.started) })
	select {
	case <-ctx.Done():
		return 0, ctx.Err()
	case <-r.stop:
		return 0, io.EOF
	}
}

func (r *missingPieceReader) Seek(offset int64, whence int) (int64, error) {
	switch whence {
	case io.SeekStart:
		r.pos = offset
	case io.SeekCurrent:
		r.pos += offset
	case io.SeekEnd:
		r.pos = 8192 + offset
	}
	return r.pos, nil
}

// Use a real local HTTP connection: client cancellation must propagate through
// ServeContent while the swarm has no bytes, without dropping the torrent or
// stopping the server between three retries.
func TestRequestReaderDisconnectReleasesEveryPeerlessRange(t *testing.T) {
	stop := make(chan struct{})
	started := make(chan chan struct{}, 3)
	released := make(chan error, 3)
	var active atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		r := &missingPieceReader{started: make(chan struct{}), stop: stop}
		active.Add(1)
		defer func() {
			active.Add(-1)
			released <- req.Context().Err()
		}()
		started <- r.started
		w.Header().Set("Content-Type", "audio/wav")
		http.ServeContent(w, req, "original.wav", time.Time{}, newRequestReader(req.Context(), r))
	}))
	t.Cleanup(func() {
		close(stop)
		server.Close()
	})
	for attempt := 0; attempt < 3; attempt++ {
		ctx, cancel := context.WithCancel(context.Background())
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, server.URL, nil)
		if err != nil {
			t.Fatal(err)
		}
		req.Header.Set("Range", "bytes=0-4095")
		done := make(chan struct{})
		go func() {
			defer close(done)
			resp, err := server.Client().Do(req)
			if err == nil {
				resp.Body.Close()
			}
		}()
		select {
		case readStarted := <-started:
			select {
			case <-readStarted:
			case <-time.After(2 * time.Second):
				cancel()
				t.Fatal("ServeContent did not enter the missing piece read")
			}
		case <-time.After(2 * time.Second):
			cancel()
			t.Fatal("HTTP handler did not start")
		}
		cancel()
		select {
		case err := <-released:
			if !errors.Is(err, context.Canceled) || active.Load() != 0 {
				t.Fatalf("attempt %d retained reader: error=%v active=%d", attempt, err, active.Load())
			}
		case <-time.After(2 * time.Second):
			t.Fatalf("attempt %d: disconnected peerless request retained its reader", attempt)
		}
		<-done
	}
}

type contextBytesReader struct{ *bytes.Reader }

func (r contextBytesReader) ReadContext(ctx context.Context, p []byte) (int, error) {
	if err := ctx.Err(); err != nil {
		return 0, err
	}
	return r.Reader.Read(p)
}

func TestRequestReaderPreservesPartialContentAndSeeks(t *testing.T) {
	r := contextBytesReader{bytes.NewReader([]byte("original audio bytes"))}
	req := httptest.NewRequest(http.MethodGet, "/stream", nil)
	req.Header.Set("Range", "bytes=9-13")
	resp := httptest.NewRecorder()
	http.ServeContent(resp, req, "original.wav", time.Time{}, newRequestReader(req.Context(), r))
	if resp.Code != http.StatusPartialContent || resp.Body.String() != "audio" || resp.Header().Get("Content-Range") != "bytes 9-13/20" {
		t.Fatalf("range changed: status=%d body=%q range=%q", resp.Code, resp.Body.String(), resp.Header().Get("Content-Range"))
	}
}
