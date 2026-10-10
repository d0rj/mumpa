package torrent

import (
	"bytes"
	"context"
	"crypto/sha1"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"reflect"
	"sync"
	"testing"
	"time"

	"github.com/anacrolix/torrent/bencode"
	"github.com/anacrolix/torrent/metainfo"
	pp "github.com/anacrolix/torrent/peer_protocol"
	"github.com/anacrolix/torrent/storage"
)

const mumpaTestChunk = 16 * 1024
const mumpaTestPiece = 1024 * 1024

func mumpaChunkOrderFixture() *Torrent {
	length := int64(2 * mumpaTestPiece)
	t := &Torrent{
		info:   &metainfo.Info{PieceLength: mumpaTestPiece, Length: length, Pieces: make([]byte, 40)},
		length: &length, chunkSize: mumpaTestChunk, requestStrategy: 3,
		readers: make(map[*reader]struct{}),
	}
	t.pieces = []Piece{{t: t, index: 0}, {t: t, index: 1}}
	return t
}

func mumpaChunkTestReader(t *Torrent, fileOffset, pos, length int64, current pieceIndex) *reader {
	r := &reader{t: t, offset: fileOffset, pos: pos, length: length,
		pieces: pieceRange{begin: current, end: current + 1}}
	t.readers[r] = struct{}{}
	t.readerNowPieces.Add(int(current))
	return r
}

func mumpaChunkOrder(t *Torrent, piece pieceIndex) (order []int) {
	iterUndirtiedChunks(piece, t, func(chunk chunkSpec) bool {
		order = append(order, int(chunk.Begin)/mumpaTestChunk)
		return true
	})
	return
}

func TestMumpaReaderChunksPreferNearEndAndKeepWholePiece(t *testing.T) {
	tor := mumpaChunkOrderFixture()
	mumpaChunkTestReader(tor, mumpaTestPiece-7000, 0, 7000, 0)
	order := mumpaChunkOrder(tor, 0)
	if len(order) != 64 || order[0] != 63 {
		t.Fatalf("near-end order begins %v, count %d", order[:3], len(order))
	}
	seen := make(map[int]bool)
	for _, chunk := range order {
		if seen[chunk] {
			t.Fatalf("chunk %d emitted twice", chunk)
		}
		seen[chunk] = true
	}
	for chunk := 0; chunk < 64; chunk++ {
		if !seen[chunk] {
			t.Fatalf("whole-piece verification lost chunk %d", chunk)
		}
	}
	if !reflect.DeepEqual(order[1:], mumpaSequentialChunks(0, 63)) {
		t.Fatal("unrelated chunks lost their original order")
	}
}

func mumpaSequentialChunks(first, end int) (ret []int) {
	for i := first; i < end; i++ {
		ret = append(ret, i)
	}
	return
}

// The fork deliberately leaves DefaultStorage to the embedding application.
// Keep this fixture independent of TorrServer's cache and the user's files.
type mumpaChunkMemoryStorage struct {
	mu       sync.RWMutex
	data     []byte
	complete bool
}

func (s *mumpaChunkMemoryStorage) OpenTorrent(*metainfo.Info, metainfo.Hash) (storage.TorrentImpl, error) {
	return s, nil
}

func (s *mumpaChunkMemoryStorage) Piece(metainfo.Piece) storage.PieceImpl { return s }
func (s *mumpaChunkMemoryStorage) Close() error                           { return nil }

func (s *mumpaChunkMemoryStorage) ReadAt(p []byte, off int64) (int, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if off < 0 || off > int64(len(s.data)) {
		return 0, io.EOF
	}
	n := copy(p, s.data[int(off):])
	if n != len(p) {
		return n, io.EOF
	}
	return n, nil
}

func (s *mumpaChunkMemoryStorage) WriteAt(p []byte, off int64) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if off < 0 || off > int64(len(s.data)) {
		return 0, io.ErrShortWrite
	}
	n := copy(s.data[int(off):], p)
	if n != len(p) {
		return n, io.ErrShortWrite
	}
	return n, nil
}

func (s *mumpaChunkMemoryStorage) MarkComplete() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.complete = true
	return nil
}

func (s *mumpaChunkMemoryStorage) MarkNotComplete() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.complete = false
	return nil
}

func (s *mumpaChunkMemoryStorage) Completion() storage.Completion {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return storage.Completion{Complete: s.complete, Ok: true}
}

func TestMumpaReaderChunksMergeReadersAndSkipDirtyChunks(t *testing.T) {
	tor := mumpaChunkOrderFixture()
	mumpaChunkTestReader(tor, 40*mumpaTestChunk+17, 0, 3*mumpaTestChunk, 0)
	mumpaChunkTestReader(tor, 42*mumpaTestChunk, 0, 2*mumpaTestChunk, 0)
	mumpaChunkTestReader(tor, 50*mumpaTestChunk, 0, 2*mumpaTestChunk, 0)
	tor.pieces[0].dirtyChunks.Add(0)
	tor.pieces[0].dirtyChunks.Add(41)
	order := mumpaChunkOrder(tor, 0)
	wantFirst := []int{40, 42, 43, 50, 51}
	if !reflect.DeepEqual(order[:len(wantFirst)], wantFirst) || len(order) != 62 {
		t.Fatalf("merged chunk preference: %v", order)
	}
	seen := make(map[int]bool)
	for _, chunk := range order {
		if seen[chunk] || chunk == 0 || chunk == 41 {
			t.Fatalf("duplicate or dirty chunk requested: %d", chunk)
		}
		seen[chunk] = true
	}
	count := 0
	if iterUndirtiedChunks(0, tor, func(chunk chunkSpec) bool {
		count++
		return false
	}) || count != 1 {
		t.Fatal("iterator ignored the caller's pipeline limit")
	}
}

func TestMumpaReaderChunksRespectOffsetEOFAndCancellation(t *testing.T) {
	tor := mumpaChunkOrderFixture()
	r := mumpaChunkTestReader(tor, mumpaTestPiece-100, 39*mumpaTestChunk+101,
		40*mumpaTestChunk+100, 1)
	order := mumpaChunkOrder(tor, 1)
	if order[0] != 39 || order[1] != 0 {
		t.Fatalf("file-relative position or EOF clamp lost: %v", order[:3])
	}
	// Removing a reader on Close/cancellation must immediately remove its
	// preference. Ordinary and readahead pieces keep the original order.
	delete(tor.readers, r)
	if !reflect.DeepEqual(mumpaChunkOrder(tor, 1), mumpaSequentialChunks(0, 64)) {
		t.Fatal("closed reader left chunk preference behind")
	}
	mumpaChunkTestReader(tor, 48*mumpaTestChunk, 0, mumpaTestChunk, 0)
	if !reflect.DeepEqual(mumpaChunkOrder(tor, 1), mumpaSequentialChunks(0, 64)) {
		t.Fatal("reader in another piece changed ordinary chunk order")
	}
	if !reflect.DeepEqual(mumpaChunkOrder(mumpaChunkOrderFixture(), 0), mumpaSequentialChunks(0, 64)) {
		t.Fatal("no-reader piece changed order")
	}
}

// This peer sends exactly two slow blocks, then waits at a barrier. The reader
// must finish the image before that barrier opens, while SHA verification must
// wait until the complete piece arrives. Only loopback sockets are permitted.
func mumpaSlowChunkPeer(ln net.Listener, hash metainfo.Hash, data []byte,
	first chan<- uint32, release, stop <-chan struct{}) error {
	conn, err := ln.Accept()
	if err != nil {
		return err
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(10 * time.Second))
	var hs [68]byte
	if _, err := io.ReadFull(conn, hs[:]); err != nil {
		return err
	}
	if string(hs[:20]) != pp.Protocol || !bytes.Equal(hs[28:48], hash[:]) {
		return fmt.Errorf("unexpected local peer handshake")
	}
	for i := 20; i < 28; i++ {
		hs[i] = 0 // Disable extensions: this fixture only needs BEP 3 messages.
	}
	copy(hs[48:], "-MP0004-chunk-fixture")
	if _, err := conn.Write(hs[:]); err != nil {
		return err
	}
	if _, err := conn.Write([]byte{0, 0, 0, 2, 5, 0x80, 0, 0, 0, 1, 1}); err != nil {
		return err
	}
	served := 0
	for {
		var prefix [4]byte
		if _, err := io.ReadFull(conn, prefix[:]); err != nil {
			return err
		}
		length := binary.BigEndian.Uint32(prefix[:])
		if length == 0 {
			continue
		}
		if length > 64*1024 {
			return fmt.Errorf("oversized local peer message")
		}
		body := make([]byte, length)
		if _, err := io.ReadFull(conn, body); err != nil {
			return err
		}
		if body[0] != 6 {
			continue
		}
		if len(body) != 13 || binary.BigEndian.Uint32(body[1:5]) != 0 {
			return fmt.Errorf("invalid local request")
		}
		begin, size := binary.BigEndian.Uint32(body[5:9]), binary.BigEndian.Uint32(body[9:13])
		if size == 0 || size > mumpaTestChunk || int64(begin)+int64(size) > int64(len(data)) {
			return fmt.Errorf("invalid local chunk bounds")
		}
		if served == 0 {
			first <- begin
		}
		if served < 2 {
			select {
			case <-time.After(150 * time.Millisecond):
			case <-stop:
				return nil
			}
		} else {
			select {
			case <-release:
			case <-stop:
				return nil
			}
		}
		packet := make([]byte, 13+int(size))
		binary.BigEndian.PutUint32(packet[:4], 9+size)
		packet[4] = 7
		binary.BigEndian.PutUint32(packet[9:13], begin)
		copy(packet[13:], data[int(begin):int(begin+size)])
		if _, err := conn.Write(packet); err != nil {
			return err
		}
		served++
	}
}

func TestMumpaReaderChunksSlowLocalPeerEarlyImageAndSHA(t *testing.T) {
	data := make([]byte, mumpaTestPiece)
	for i := range data {
		data[i] = byte(i % 251)
	}
	imageOffset := mumpaTestPiece - 2*mumpaTestChunk + 73
	image := data[imageOffset:]
	pieceHash := sha1.Sum(data)
	info := metainfo.Info{Name: "original-local-artwork", PieceLength: mumpaTestPiece,
		Pieces: pieceHash[:], Files: []metainfo.FileInfo{
			{Path: []string{"prefix.bin"}, Length: int64(imageOffset)},
			{Path: []string{"cover.jpg"}, Length: int64(len(image))},
		}}
	infoBytes, err := bencode.Marshal(info)
	if err != nil {
		t.Fatal(err)
	}
	mi := &metainfo.MetaInfo{InfoBytes: infoBytes}
	cfg := NewDefaultClientConfig()
	store := &mumpaChunkMemoryStorage{data: make([]byte, len(data))}
	cfg.DefaultStorage = store
	cfg.DataDir = t.TempDir()
	cfg.SetListenAddr("127.0.0.1:0")
	cfg.NoDHT, cfg.DisableTrackers, cfg.DisablePEX = true, true, true
	cfg.DisableUTP, cfg.DisableIPv6, cfg.NoDefaultPortForwarding = true, true, true
	cfg.DisableEncryption = true
	cfg.NominalDialTimeout, cfg.MinDialTimeout = time.Second, time.Second
	cl, err := NewClient(cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer cl.Close()
	tor, err := cl.AddTorrent(mi)
	if err != nil {
		t.Fatal(err)
	}
	if tor.requestStrategy != 3 {
		t.Fatalf("fixture uses strategy %d, want production strategy 3", tor.requestStrategy)
	}
	var file *File
	for _, f := range tor.Files() {
		if f.Length() == int64(len(image)) {
			file = f
		}
	}
	if file == nil {
		t.Fatal("fixture image file missing")
	}
	r := file.NewReader()
	defer r.Close()
	r.SetReadahead(0)
	r.SetResponsive()
	ln, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	first, release, stop := make(chan uint32, 1), make(chan struct{}), make(chan struct{})
	defer close(stop)
	peerDone := make(chan error, 1)
	peerExited := make(chan struct{})
	go func() {
		defer close(peerExited)
		peerDone <- mumpaSlowChunkPeer(ln, mi.HashInfoBytes(), data, first, release, stop)
	}()
	t.Cleanup(func() {
		select {
		case <-peerExited:
		case <-time.After(time.Second):
			t.Error("local peer goroutine remained after client shutdown")
		}
	})
	addr := ln.Addr().(*net.TCPAddr)
	tor.AddPeers([]Peer{{IP: addr.IP, Port: addr.Port}})
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	started := time.Now()
	got := make([]byte, len(image))
	for pos := 0; pos < len(got); {
		n, err := r.ReadContext(ctx, got[pos:])
		pos += n
		if err != nil && (err != io.EOF || pos != len(got)) {
			t.Fatalf("early image unavailable before whole-piece barrier: %v (%d bytes)", err, pos)
		}
	}
	if !bytes.Equal(got, image) {
		t.Fatal("responsive image bytes differ")
	}
	select {
	case begin := <-first:
		if begin != 62*mumpaTestChunk {
			t.Fatalf("first wire Request offset = %d, want image chunk %d", begin, 62*mumpaTestChunk)
		}
	default:
		t.Fatal("image arrived without a recorded peer request")
	}
	if tor.PieceState(0).Complete || store.Completion().Complete || tor.BytesCompleted() >= mumpaTestPiece {
		t.Fatal("partial image bypassed whole-piece verification")
	}
	t.Logf("image available in %s, first chunk 62, whole piece still unverified", time.Since(started))
	close(release)
	tor.DownloadAll()
	deadline := time.Now().Add(5 * time.Second)
	for !tor.PieceState(0).Complete {
		if time.Now().After(deadline) {
			select {
			case err := <-peerDone:
				t.Fatalf("peer stopped before SHA verification: %v", err)
			default:
				t.Fatal("complete original piece did not pass SHA verification")
			}
		}
		time.Sleep(5 * time.Millisecond)
	}
	if tor.BytesCompleted() != mumpaTestPiece {
		t.Fatal("verified piece lost bytes")
	}
	store.mu.RLock()
	verifiedHash := sha1.Sum(store.data)
	store.mu.RUnlock()
	if !store.Completion().Complete || verifiedHash != pieceHash {
		t.Fatal("piece was marked complete without the original SHA-1 payload")
	}
	t.Log("complete piece verified through the unchanged SHA-1 path")
}
