package torrent

import pp "github.com/anacrolix/torrent/peer_protocol"

type mumpaChunkRange struct {
	first, last pp.Integer // inclusive, clamped to this piece
}

// Called under the Client lock, like iterUndirtiedChunks and existing reader
// priority inspection. No extra lock or goroutine may outlive a closed reader.
// Only current reader pieces get a preference; readahead and ordinary pieces
// retain strategy 3's sequential chunk order.
func mumpaReaderChunkRanges(piece pieceIndex, t *Torrent) []mumpaChunkRange {
	if !t.readerNowPieces.Contains(int(piece)) {
		return nil
	}
	pieceStart := int64(piece) * t.info.PieceLength
	pieceEnd := pieceStart + int64(t.pieceLength(piece))
	var ranges []mumpaChunkRange
	for r := range t.readers {
		if r.pieces.begin != piece || r.pieces.end <= piece || r.pos < 0 || r.pos >= r.length {
			continue
		}
		start := r.torrentOffset(r.pos)
		end := r.torrentOffset(r.length)
		if start < pieceStart {
			start = pieceStart
		}
		if end > pieceEnd {
			end = pieceEnd
		}
		if end <= start {
			continue
		}
		// Include each remaining byte in the reader's file within its current
		// piece, rather than just one byte of a zero-readahead window. This
		// keeps successive responsive reads fast while pos stays in a piece.
		ranges = append(ranges, mumpaChunkRange{
			first: pp.Integer((start - pieceStart) / int64(t.chunkSize)),
			last:  pp.Integer((end - 1 - pieceStart) / int64(t.chunkSize)),
		})
	}
	return ranges
}

func mumpaChunkInRanges(chunk pp.Integer, ranges []mumpaChunkRange) bool {
	for _, r := range ranges {
		if chunk >= r.first && chunk <= r.last {
			return true
		}
	}
	return false
}
