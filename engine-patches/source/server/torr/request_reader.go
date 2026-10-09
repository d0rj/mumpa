package torr

import (
	"context"
	"io"
)

type contextReadSeeker interface {
	io.Seeker
	ReadContext(context.Context, []byte) (int, error)
}

// requestReader preserves ServeContent's seeks and ranges while binding every
// blocking torrent read to this HTTP request. The stream owner closes the
// original reader only after ServeContent returns, never during a read.
type requestReader struct {
	contextReadSeeker
	ctx context.Context
}

func newRequestReader(ctx context.Context, reader contextReadSeeker) io.ReadSeeker {
	return requestReader{contextReadSeeker: reader, ctx: ctx}
}

func (r requestReader) Read(p []byte) (int, error) {
	return r.ReadContext(r.ctx, p)
}
